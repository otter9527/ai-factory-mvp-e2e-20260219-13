"""Small module used by the MVP worker flow."""


def add(a, b):
    return a + b


def multiply(a, b):
    return a * b


def safe_divide(a, b):
    if b == 0:
        raise ValueError("division by zero")
    return a / b
