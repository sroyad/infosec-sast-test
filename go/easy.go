package main

import (
	"database/sql"
	"fmt"
	"net/http"
	"os"
)

func main() {

	http.HandleFunc("/login", func(w http.ResponseWriter, r *http.Request) {
		user := r.URL.Query().Get("user")
		pass := r.URL.Query().Get("pass")
		// vulnerable: user input directly in query
		q := fmt.Sprintf("SELECT * FROM users WHERE user='%s' AND pass='%s'", user, pass)
		db.Query(q)
	})


	http.HandleFunc("/show", func(w http.ResponseWriter, r *http.Request) {
		file := r.URL.Query().Get("file")
		// vulnerable: no input validation
		data, _ := os.ReadFile("/tmp/" + file)
		w.Write(data)
	})


	http.HandleFunc("/run", func(w http.ResponseWriter, r *http.Request) {
		name := r.URL.Query().Get("person")
		_ = os.system("echo Hello " + name)
	})
}
var db *sql.DB
