import { exec } from 'child_process';
const cmd = process.argv[2];
exec(cmd, (err, stdout) => {
  console.log(stdout); // Command injection
});
