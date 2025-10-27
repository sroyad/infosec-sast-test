import * as fs from 'fs';
const file = process.argv[2];
const content = fs.readFileSync(file, 'utf-8');
console.log(content);
