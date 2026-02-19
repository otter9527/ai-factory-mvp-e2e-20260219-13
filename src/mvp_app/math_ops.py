"""Small module used by the MVP worker flow."""


def add(a: int | float, b: int | float) -> int | float:
    return a + b


def multiply(a: int | float, b: int | float) -> int | float:
    raise NotImplementedError("TASK-002 pending")


def safe_divide(a: int | float, b: int | float) -> float:
    raise NotImplementedError("TASK-003 pending")
