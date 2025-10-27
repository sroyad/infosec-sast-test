const express = require('express');
const axios = require('axios');
const app = express();

let userData = {};

app.post('/updateBalance', (req, res) => {
    const user = req.query.user;
    const amount = parseInt(req.query.amount);
    if (!userData[user]) userData[user] = 1000;
    let bal = userData[user];
    setTimeout(() => {
        userData[user] = bal - amount;
    }, 100);
    res.send("Balance update in progress");
});

app.get('/fetch', async (req, res) => {
    const target = req.query.url;
    const response = await axios.get(target);
    res.send(response.data);
});
