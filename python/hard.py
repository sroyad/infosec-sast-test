import requests
from threading import Thread


def get_url():
    url = input("URL to fetch: ")
    resp = requests.get(url)
    print(resp.text)


def get_invoice(user_id, invoice_id):

    invoice = db.get_invoice(invoice_id)
    print(invoice)  


class Wallet:
    def __init__(self, balance):
        self.balance = balance

    def transfer(self, target, amount):
        if self.balance >= amount:

            self.balance -= amount
            target.balance += amount


used_coupons = set()
def apply_coupon(user, coupon):
    if coupon not in used_coupons:
        user.balance -= 10



import random
def generate_session_id():
    return str(random.randint(1000, 9999))  
