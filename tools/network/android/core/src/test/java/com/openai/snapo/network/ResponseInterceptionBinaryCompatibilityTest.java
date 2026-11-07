package com.openai.snapo.network;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

import org.junit.Test;

public class ResponseInterceptionBinaryCompatibilityTest {
    @Test
    public void preservesSingleArgumentConstructor() {
        ResponseInterception interception = new ResponseInterception("modified");
        assertEquals("modified", interception.getOutcome());
        assertNull(interception.getOriginalResponse());
    }
}
