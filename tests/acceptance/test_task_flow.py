import pytest

from src.mvp_app.math_ops import add, multiply, safe_divide


@pytest.mark.task_001
def test_task_001_add() -> None:
    assert add(10, 7) == 17


@pytest.mark.task_002
def test_task_002_multiply() -> None:
    assert multiply(6, 7) == 42


@pytest.mark.task_003
def test_task_003_safe_divide() -> None:
    assert safe_divide(9, 3) == 3


@pytest.mark.integration
def test_integration_chain() -> None:
    assert safe_divide(multiply(add(1, 2), 3), 3) == 3
