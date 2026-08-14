/**
 * Covers the shared Models API transport's request-building paths (the callout itself is skipped in
 * test context via the testChat/testEmbed hooks) and the model-JSON parser's recovery tiers.
 */
@isTest
private class EinsteinAiClientTest {

    @isTest
    static void chatBuildsRequestAndReturnsHookedResponse() {
        EinsteinAiClient.testChatResponse = 'hello from the model';
        System.assertEquals('hello from the model',
            EinsteinAiClient.chat('sfdc_ai__DefaultGPT4Omni', 'say hello'));

        EinsteinAiClient.testChatResponse = null;
        System.assertEquals('', EinsteinAiClient.chat('sfdc_ai__DefaultGPT4Omni', 'say hello'),
            'no hooked response -> empty string, the empty-generation convention');
    }

    @isTest
    static void embedBuildsRequestAndReturnsHookedVectors() {
        System.assertEquals(null, EinsteinAiClient.embed('m', null), 'null input -> null');
        System.assertEquals(null, EinsteinAiClient.embed('m', new List<String>()), 'empty input -> null');

        EinsteinAiClient.testEmbedResponse = new List<List<Double>>{
            new List<Double>{ 0.1, 0.2 }, null };
        List<List<Double>> out = EinsteinAiClient.embed('m', new List<String>{ 'a', 'b' });
        System.assertEquals(2, out.size());
        System.assertEquals(0.2, out[0][1]);
        System.assertEquals(null, out[1], 'null elements are preserved per input');
    }

    @isTest
    static void parseModelJsonAcceptsBareObject() {
        Map<String, Object> m = EinsteinAiClient.parseModelJson('{"a": 1, "b": "x"}');
        System.assertEquals(1, m.get('a'));
        System.assertEquals('x', m.get('b'));
    }

    @isTest
    static void parseModelJsonTriesBareObjectBeforeFenceStripping() {
        // The payload legitimately contains a fenced code block; fence-stripping first would carve it
        // out instead of the JSON. The bare object must win.
        String raw = '{"draft": "Run this:\\n```\\nsfdx force:source:push\\n```\\nDone.", "ok": true}';
        Map<String, Object> m = EinsteinAiClient.parseModelJson(raw);
        System.assertEquals(true, m.get('ok'), 'bare object parsed despite embedded fence');
        System.assert(String.valueOf(m.get('draft')).contains('sfdx'), 'fenced content survives');
    }

    @isTest
    static void parseModelJsonStripsMarkdownFences() {
        Map<String, Object> a = EinsteinAiClient.parseModelJson('```json\n{"k":"v"}\n```');
        System.assertEquals('v', a.get('k'), '```json fence stripped');
        Map<String, Object> b = EinsteinAiClient.parseModelJson('```\n{"k":"w"}\n```');
        System.assertEquals('w', b.get('k'), 'bare ``` fence stripped');
    }

    @isTest
    static void parseModelJsonCarvesObjectOutOfProse() {
        Map<String, Object> m = EinsteinAiClient.parseModelJson(
            'Sure! Here is the JSON you asked for: {"verdict":"approve"} — hope that helps.');
        System.assertEquals('approve', m.get('verdict'), 'outermost {...} span carved out of prose');
    }

    @isTest
    static void parseModelJsonReturnsNullWhenUnrecoverable() {
        System.assertEquals(null, EinsteinAiClient.parseModelJson(null), 'null in');
        System.assertEquals(null, EinsteinAiClient.parseModelJson('   '), 'blank in');
        System.assertEquals(null, EinsteinAiClient.parseModelJson('totally not json'), 'no object');
        System.assertEquals(null, EinsteinAiClient.parseModelJson('[1, 2, 3]'), 'non-object JSON');
    }
}
