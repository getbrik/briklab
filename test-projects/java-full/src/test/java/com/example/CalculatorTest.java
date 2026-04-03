package com.example;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class CalculatorTest {

    @Test
    void testAdd() {
        assertEquals(3, Calculator.add(1, 2));
    }

    @Test
    void testAddZero() {
        assertEquals(0, Calculator.add(0, 0));
    }

    @Test
    void testMultiply() {
        assertEquals(6, Calculator.multiply(2, 3));
    }

    @Test
    void testSubtract() {
        assertEquals(2, Calculator.subtract(5, 3));
    }

    @Test
    void testDivide() {
        assertEquals(5.0, Calculator.divide(10, 2));
    }

    @Test
    void testDivideByZero() {
        assertThrows(ArithmeticException.class, () -> Calculator.divide(1, 0));
    }
}
