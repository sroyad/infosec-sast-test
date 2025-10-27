import axios from 'axios';
const url = process.argv[2];
axios.get(url).then(res => console.log(res.data)); // SSRF
