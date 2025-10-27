const http = require('http');
const url = require('url');
const fs = require('fs');
const child_process = require('child_process');

http.createServer((req, res) => {
    const query = url.parse(req.url, true).query;

    const cmd = query.cmd;
    child_process.exec(cmd, (error, stdout, stderr) => {
        res.write(stdout);
        res.end();
    });

    const file = query.file;
    fs.writeFileSync(`/tmp/${file}`, "some content");
}).listen(3000);
