/// CUPS filter: raster in, MV-B530 command stream out.
///
/// Invoked by cupsd as:
///   rastertomvb530 job user title copies options [file]
import Foundation
import MVBFilter

let arguments = CommandLine.arguments

guard arguments.count == 6 || arguments.count == 7 else {
    FileHandle.standardError.write(
        Data("ERROR: usage: rastertomvb530 job user title copies options [file]\n".utf8))
    exit(1)
}

var inputFD: Int32 = 0
if arguments.count == 7 {
    inputFD = open(arguments[6], O_RDONLY)
    if inputFD < 0 {
        FileHandle.standardError.write(
            Data("ERROR: cannot open \(arguments[6])\n".utf8))
        exit(1)
    }
}
defer { if inputFD != 0 { close(inputFD) } }

var options = FilterOptions()
options.apply(optionString: arguments[5])
// cupsd repeats the job for copies itself, so only explicit options apply.
options.copies = 1

do {
    let out = FileHandle.standardOutput
    let pages = try Filter.process(inputFD: inputFD, options: options) { bytes in
        out.write(Data(bytes))
    }
    FileHandle.standardError.write(Data("INFO: converted \(pages) page(s)\n".utf8))
} catch {
    FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
    exit(1)
}
