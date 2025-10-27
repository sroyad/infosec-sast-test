const express = require('express');
const app = express();
const session = require('express-session');
const cors = require('cors');

app.use(cors());
app.use(session({ secret: 'secret', saveUninitialized: true, resave: true }));

app.post('/login', (req, res) => {
    req.session.user = req.body.user;
    res.send("Logged in");
});

app.post('/transfer', (req, res) => {
    res.send("Transferred");
});
