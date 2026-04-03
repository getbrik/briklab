using Xunit;
using Calculator;

namespace Calculator.Tests;

public class CalculatorTests
{
    [Fact]
    public void TestAdd() => Assert.Equal(3, Calc.Add(1, 2));

    [Fact]
    public void TestAddZero() => Assert.Equal(0, Calc.Add(0, 0));

    [Fact]
    public void TestAddNegative() => Assert.Equal(0, Calc.Add(-1, 1));

    [Fact]
    public void TestMultiply() => Assert.Equal(6, Calc.Multiply(2, 3));

    [Fact]
    public void TestMultiplyZero() => Assert.Equal(0, Calc.Multiply(0, 5));
}
