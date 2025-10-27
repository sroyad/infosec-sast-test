import Foundation

let tempDir = NSTemporaryDirectory()
let path = "\(tempDir)/tmp.txt"
try! "text".write(toFile: path, atomically: true, encoding: .utf8)
let content = try! String(contentsOfFile: path)
print(content)
