package main

import (
	"fmt"
	"net/http"
	"sync"
)

var balances = map[string]int{
	"alice": 100,
	"bob":   50,
}

var mu sync.Mutex


func transfer(from, to string, amount int) {
	if balances[from] >= amount {
		// no lock!
		balances[from] -= amount
		balances[to] += amount
	}
}


var usedCoupons = map[string]bool{}

func applyCoupon(w http.ResponseWriter, user, coupon string) {
	if !usedCoupons[coupon] {
		// Vulnerability: Does not record usage!
		balances[user] += 50
	}
}


func fetchURL(w http.ResponseWriter, r *http.Request) {
	target := r.URL.Query().Get("url")
	resp, _ := http.Get(target) // No validation: SSRF
	fmt.Fprint(w, resp.Status)
}

func main() {
	http.HandleFunc("/transfer", func(w http.ResponseWriter, r *http.Request) {
		from := r.URL.Query().Get("from")
		to := r.URL.Query().Get("to")
		amount, _ := strconv.Atoi(r.URL.Query().Get("amt"))
		transfer(from, to, amount)
	})

	http.HandleFunc("/apply-coupon", func(w http.ResponseWriter, r *http.Request) {
		user := r.URL.Query().Get("user")
		coupon := r.URL.Query().Get("coupon")
		applyCoupon(w, user, coupon)
	})

	http.HandleFunc("/ssrf", fetchURL)
}
