import Foundation
let path = CommandLine.arguments[1]
let content = try! String(contentsOfFile: path)
print(content)
