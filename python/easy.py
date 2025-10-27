import os


param = input("Enter a parameter: ")
os.system(f"echo Printing {param}") 


expr = input("Enter math to eval: ")
print(eval(expr))  


with open('config.txt') as f:
    print(f.read())  


filename = input("Which file? ")
with open("/tmp/" + filename) as file:
    print(file.read())
