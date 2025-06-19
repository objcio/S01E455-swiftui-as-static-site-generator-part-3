import SwiftUI

typealias Rule = View

extension EnvironmentValues {
    @Entry var outputDir: URL = .temporaryDirectory
    @Entry var inputDir: URL = .temporaryDirectory
}

struct WritePayload: Equatable {
    var name: String
    var data: Data
}

struct Write: Rule {
    @Environment(\.outputDir) var outputDir
    var payload: WritePayload

    init(name: String = "index.html", data: Data) {
        self.payload = WritePayload(name: name, data: data)
    }

    init(name: String = "index.html", _ string: String) {
        self.payload = WritePayload(name: name, data: string.data(using: .utf8)!)
    }

    var body: some View {
        Text("Writing \(payload.data) to \(payload.name)")
            .onChange(of: payload, initial: true) {
                run()
            }
            .onChange(of: outputDir) { run() }
    }

    func run() {
        let fileURL = outputDir.appending(path: payload.name)
        try! FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try! payload.data.write(to: fileURL)
    }
}

extension View {
    func outputDir(_ name: String) -> some View {
        transformEnvironment(\.outputDir) { url in
            url.append(path: name)
        }
    }

    func inputDir(_ name: String) -> some View {
        transformEnvironment(\.inputDir) { url in
            url.append(path: name)
        }
    }
}

struct Read<Nested: View>: View {
    @Environment(\.inputDir) private var inputDir
    @State private var observer = FileObserver { url in
        try? Data(contentsOf: url)
    }
    var path: String
    var nested: (Data) -> Nested

    init(_ path: String, nested: @escaping (Data?) -> Nested) {
        self.path = path
        self.nested = nested
    }

    var body: some View {
        VStack {
            let url = inputDir.appending(path: path)
            Text("Reading \(path)")
                .onChange(of: url, initial: true) {
                    observer.fileURL = url
                }
            if let data = observer.contents {
                nested(data)
            }
        }
    }
}

struct ReadDir<Nested: View>: View {
    @Environment(\.inputDir) private var inputDir
    @State private var observer = FileObserver<[String]> { url in
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let path = url.path(percentEncoded: false)
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return try? fm.contentsOfDirectory(atPath: path)
    }
    var nested: ([String]) -> Nested

    init(@ViewBuilder nested: @escaping ([String]) -> Nested) {
        self.nested = nested
    }

    var body: some View {
        VStack {
            Text("Reading directory \(inputDir)")
                .onChange(of: inputDir, initial: true) {
                    observer.fileURL = inputDir
                }
            if let files = observer.contents {
                nested(files)
            }
        }
    }
}

struct BlogpostTitleKey: PreferenceKey {
    static var defaultValue: [String] = []
    static func reduce(value: inout [String], nextValue: () -> [String]) {
        value.append(contentsOf: nextValue())
    }
}

struct Blogpost: Rule {
    var path: String
    var body: some View {
        Read(path) { data in
            Write(data: data!)
                .outputDir((path as NSString).deletingPathExtension)
        }
        .preference(key: BlogpostTitleKey.self , value: [path])
    }
}

struct Blog: Rule {
    @State var titles: [String] = []

    var body: some View {
        ReadDir() { files in
            Text(titles.joined(separator: ", "))
            Write(titles.joined(separator: "<br>"))
            ForEach(files, id: \.self) { file in
                Blogpost(path: file)
            }
        }
        .onPreferenceChange(BlogpostTitleKey.self) {
            titles = $0
        }
    }
}

struct MySite: Rule {
    @State var outputDir: URL = .temporaryDirectory.appending(path: "static_site")
    @State var inputDir: URL = {
        let base = #file
        return URL(fileURLWithPath: base).deletingLastPathComponent().appending(path: "input")
    }()
    var body: some View {
        VStack(alignment: .leading) {
            Read("index.md") { data in
                Write(data: data!)
            }
            Write("About this site")
                .outputDir("about")
            Blog()
                .inputDir("posts")
                .outputDir("posts")

        }
        .environment(\.inputDir, inputDir)
        .environment(\.outputDir, outputDir)
        .toolbar {
            Button("Open Output Dir") {
                NSWorkspace.shared.open(outputDir)
            }
        }
    }
}

import Observation

@Observable @MainActor class FileObserver<Content> {
    var fileURL: URL? = nil {
        didSet {
            observe()
        }
    }
    var contents: Content? = nil
    var read: (URL) -> Content?
    var dispatchSource: DispatchSourceFileSystemObject? = nil

    init(read: @escaping (URL) -> Content?) {
        self.read = read
    }

    func observe() {
        cancel()
        let fd = open(self.fileURL!.path(percentEncoded: false), O_EVTONLY)
        guard fd != -1 else { return }
        let obj = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .all, queue: .main)
        obj.setEventHandler { [weak self] in
            self?.handle(event: obj.data)
        }
        obj.setCancelHandler {
            close(fd)
        }
        reload()
        obj.resume()
        dispatchSource = obj
    }

    func cancel() {
        dispatchSource?.cancel()
        dispatchSource = nil
    }

    func handle(event: DispatchSource.FileSystemEvent) {
        if event.contains(.write) {
            reload()
        } else if event.contains(.delete) {
            observe()
        } else if event.contains(.attrib) {
            // nothing
        } else {
            print("Unhandled", event.pretty)
        }
    }

    func reload() {
        guard let url = fileURL else {
            contents = nil
            return
        }

        self.contents = read(url)
    }
}

extension DispatchSource.FileSystemEvent {
    var pretty: String {
        var result: [String] = []

        if self.contains(.delete) {
            result.append("delete")
        } else if self.contains(.write) {
            result.append("write")
        } else if self.contains(.extend) {
            result.append("extend")
        } else if self.contains(.attrib) {
            result.append("attrib")
        } else if self.contains(.link) {
            result.append("link")
        } else if self.contains(.rename) {
            result.append("rename")
        } else if self.contains(.revoke) {
            result.append("revoke")
        } else if self.contains(.funlock) {
            result.append("funlock")
        }
        return result.joined(separator: ", ")
    }
}
