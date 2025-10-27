import Foundation
let cmd = readLine()!
let task = Process()
task.launchPath = "/bin/bash"
task.arguments = ["-c", cmd]
task.launch()  // Command injection
