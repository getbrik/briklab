from api import greet


def test_greet():
    assert greet("api") == "hello, api"
