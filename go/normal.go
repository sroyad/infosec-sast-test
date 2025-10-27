package main

import (
	"encoding/json"
	"net/http"
	"os"
)

var hardcodedSecret = "ultrasecret" // Hardcoded secret

func main() {

	http.HandleFunc("/unmarshal", func(w http.ResponseWriter, r *http.Request) {
		var obj map[string]interface{}
		json.NewDecoder(r.Body).Decode(&obj) // No validation
	})


	http.HandleFunc("/price", func(w http.ResponseWriter, r *http.Request) {
		vip := r.URL.Query().Get("vip")
		price := 100
		if vip == "true" {
			price /= 10 // 90% off, no server-side verification!
		}
		w.Write([]byte(fmt.Sprintf("%d", price)))
	})


	http.HandleFunc("/download-config", func(w http.ResponseWriter, r *http.Request) {
		data, _ := os.ReadFile("config.yaml")
		w.Write(data) // Exposes sensitive config!
	})
}
