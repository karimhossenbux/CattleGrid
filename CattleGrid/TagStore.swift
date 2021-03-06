//
//  TagStore.swift
//  CattleGrid
//
//  Created by Eric Betts on 4/10/20.
//  Copyright © 2020 Eric Betts. All rights reserved.
//

import Foundation
import SwiftUI
import CoreNFC
import amiitool

enum MifareCommands : UInt8 {
    case READ = 0x30
    case WRITE = 0xA2
    case PWD_AUTH = 0x1B
}

let NTAG_PAGE_SIZE = 4

enum NTAG215Pages : UInt8 {
    case staticLockBits = 2
    case capabilityContainer = 3
    case userMemoryFirst = 4
    case characterModelHead = 21
    case characterModelTail = 22
    case userMemoryLast = 129
    case dynamicLockBits = 130
    case cfg0 = 131
    case cfg1 = 132
    case pwd = 133
    case pack = 134
    case total = 135
}

let SLB = Data([0x00, 0x00, 0x0f, 0xe0])
let CC = Data([0xf1, 0x10, 0xff, 0xee])
let DLB = Data([0x01, 0x00, 0x0f, 0xbd])
let CFG0 = Data([0x00, 0x00, 0x00, 0x04])
let CFG1 = Data([0x5f, 0x00, 0x00, 0x00])
let PACKRFUI = Data([0x80, 0x80, 0x00, 0x00])

class TagStore : NSObject, ObservableObject, NFCTagReaderSessionDelegate {
    static let shared = TagStore()
    @Published private(set) var amiibos: [URL] = []
    @Published private(set) var selected: URL?
    @Published private(set) var progress : Float = 0
    @Published private(set) var error : String = ""
    @Published private(set) var readingAvailable : Bool = NFCReaderSession.readingAvailable

    var lastPageWritten : UInt8 = 0 {
        willSet(newVal) {
            self.progress = Float(newVal) / Float(NTAG215Pages.total.rawValue)
        }
    }

    let fm = FileManager.default
    var amiitool : Amiitool?
    var plain : Data = Data()
    var watcher : DirectoryWatcher? = nil

    func start() {
        print("Start")
        guard let key_retail = Bundle.main.path(forResource: "key_retail", ofType: "bin", inDirectory: nil) else {
            return
        }

        self.amiitool = Amiitool(path: key_retail)

        self.loadList()

        if self.watcher == nil {
            self.watcher = DirectoryWatcher.watch(getDocumentsDirectory())
            guard let watcher = watcher else {
                return
            }

            watcher.onFilesChanged = {
              self.loadList()
            }
        }
        guard let watcher = self.watcher else {
            print("self.watcher not defined")
            return
        }
        if (watcher.startWatching()) {
            print("Documents watching started")
        }
    }

    func stop() {
        guard let watcher = self.watcher else {
            print("self.watcher not defined")
            return
        }
        if (watcher.stopWatching()) {
            print("Documents watching paused")
        }
    }

    func loadList() {
        let dirEnumerator = fm.enumerator(at: getDocumentsDirectory(), includingPropertiesForKeys: nil, options: [.includesDirectoriesPostOrder, .producesRelativePathURLs])!
        var fileURLs: [URL] = []
        for case let fileURL as URL in dirEnumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]),
                let isDirectory = resourceValues.isDirectory
                else {
                    continue
            }
            if (!isDirectory) {
                fileURLs.append(fileURL)
            }
        }
        amiibos = fileURLs.sorted(by: { $0.relativePath < $1.relativePath})
    }

    func getDocumentsDirectory() -> URL {
        #if JAILBREAK
        return URL(fileURLWithPath: "/var/mobile/tagbin/", isDirectory: true)
        #else
        return fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        #endif
    }

    func load(_ amiiboPath: URL) {
        do {
            let tag = try Data(contentsOf: amiiboPath)
            guard let amiitool = self.amiitool else {
                self.error = "Internal error: amiitool not initialized"
                return
            }

            let start = NTAG_PAGE_SIZE * Int(NTAG215Pages.characterModelHead.rawValue)
            let end = NTAG_PAGE_SIZE * Int(NTAG215Pages.characterModelTail.rawValue+1)
            let id = tag.subdata(in: start..<end)
            print("character id: \(id.hexDescription)")

            plain = amiitool.unpack(tag)
            print("\(amiiboPath.lastPathComponent) loaded")
            self.selected = amiiboPath
        } catch {
            print("Couldn't read \(amiiboPath)")
        }
    }

    func scan() {
        print("Scan")
        self.error = ""

        if let session = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: nil) {
            session.alertMessage = "Hold your device near a tag to write."
            session.begin()
        }
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        print("reader active \(session)")
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        print("didInvalidateWithError: \(error.localizedDescription)")
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        print("didDetect: \(tags)")

        if case let NFCTag.miFare(tag) = tags.first! {
            session.connect(to: tags.first!) { (error: Error?) in
                if ((error) != nil) {
                    print("Error during connect: \(error!.localizedDescription)")
                    DispatchQueue.main.async {
                        self.error = "Error during connect: \(error!.localizedDescription)"
                        self.lastPageWritten = 0
                    }
                    return
                }

                self.connected(tag, session: session)
            }
        } else {
            print("Ignoring non-mifare tag")
            DispatchQueue.main.async {
                self.error = "Ignoring non-mifare tag"
            }
        }
    }

    func connected(_ tag: NFCMiFareTag, session: NFCTagReaderSession) {
        let read = Data([MifareCommands.READ.rawValue, 0])
        tag.sendMiFareCommand(commandPacket: read) { (data, error) in
            if ((error) != nil) {
                print("Error during read: \(error!.localizedDescription)")
                DispatchQueue.main.async {
                    self.error = "Error during read: \(error!.localizedDescription)"
                    self.lastPageWritten = 0
                }
                session.invalidate()
                return
            }

            guard let amiitool = self.amiitool else {
                DispatchQueue.main.async {
                    self.error = "Internal error: amiitool not initialized"
                }
                return
            }

            //Amiitool plain text stores first 2 pages (uid) towards the end
            //TODO: is uid even used in encryption/signing?
            self.plain.replaceSubrange(468..<476, with: data.subdata(in: 0..<8))

            let modified = amiitool.pack(self.plain)
            self.writeTag(tag, newImage: modified) { () in
                print("done writing")
                DispatchQueue.main.async {
                    self.lastPageWritten = 0
                    self.error = ""
                }
                session.invalidate()
            }
        }
    }

    func writeTag(_ tag: NFCMiFareTag, newImage: Data, completionHandler: @escaping () -> Void) {
        self.writeUserPages(tag, startPage: NTAG215Pages.userMemoryFirst.rawValue, data: newImage) { () in
            let pwd = self.calculatePWD(tag.identifier)
            print("\(tag.identifier.hexDescription): \(pwd.hexDescription)")
            self.writePage(tag, page: NTAG215Pages.pwd.rawValue, data: pwd) {
                self.writePage(tag, page: NTAG215Pages.pack.rawValue, data: PACKRFUI) {
                    self.writePage(tag, page: NTAG215Pages.capabilityContainer.rawValue, data: CC) {
                        self.writePage(tag, page: NTAG215Pages.cfg0.rawValue, data: CFG0) {
                            self.writePage(tag, page: NTAG215Pages.cfg1.rawValue, data: CFG1) {
                                self.writePage(tag, page: NTAG215Pages.dynamicLockBits.rawValue, data: DLB) {
                                    self.writePage(tag, page: NTAG215Pages.staticLockBits.rawValue, data: SLB) {
                                        completionHandler()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func writeUserPages(_ tag: NFCMiFareTag, startPage: UInt8, data: Data, completionHandler: @escaping () -> Void) {
        if (startPage > NTAG215Pages.userMemoryLast.rawValue) {
            completionHandler()
            return
        }

        let page = data.subdata(in: Int(startPage) * 4 ..< Int(startPage) * 4 + 4)
        writePage(tag, page: startPage, data: page) {
            self.writeUserPages(tag, startPage: startPage+1, data: data) { () in
                completionHandler()
            }
        }
    }

    func writePage(_ tag: NFCMiFareTag, page: UInt8, data: Data, completionHandler: @escaping () -> Void) {
        print("Write page \(page) \(data.hexDescription)")
        let write = Data([MifareCommands.WRITE.rawValue, page]) + data
        tag.sendMiFareCommand(commandPacket: write) { (_, error) in
            if ((error) != nil) {
                print("Error during write: \(error!.localizedDescription)")
                DispatchQueue.main.async {
                    self.error = "Error during write: \(error!.localizedDescription)"
                    self.lastPageWritten = 0
                }
                return
            }
            DispatchQueue.main.async {
                self.lastPageWritten = page
            }
            completionHandler()
        }
    }

    func dumpTag(_ tag: NFCMiFareTag, completionHandler: @escaping (Data) -> Void) {
        self.readAllPages(tag, startPage: 0, completionHandler: completionHandler)
    }

    func readAllPages(_ tag: NFCMiFareTag, startPage: UInt8, completionHandler: @escaping (Data) -> Void) {
        if (startPage >= NTAG215Pages.total.rawValue) {
            completionHandler(Data())
            return
        }
        print("Read page \(startPage)")
        let read = Data([MifareCommands.READ.rawValue, startPage])
        tag.sendMiFareCommand(commandPacket: read) { (data, error) in
            if ((error) != nil) {
                print(error as Any)
                return
            }
            self.readAllPages(tag, startPage: startPage+4) { (contents) in
                completionHandler(data + contents)
            }
        }
    }

    func calculatePWD(_ uid: Data) -> Data {
        var PWD = Data(count: 4)
        PWD[0] = uid[1] ^ uid[3] ^ 0xAA
        PWD[1] = uid[2] ^ uid[4] ^ 0x55
        PWD[2] = uid[3] ^ uid[5] ^ 0xAA
        PWD[3] = uid[4] ^ uid[6] ^ 0x55
        return PWD
    }
}
