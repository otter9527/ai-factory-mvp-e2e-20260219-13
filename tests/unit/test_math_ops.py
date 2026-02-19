from src.mvp_app.math_ops import add


def test_add_basic() -> None:
    assert add(2, 3) == 5
