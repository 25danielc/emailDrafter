/**
 * The single Einstein Models API transport for the pipeline: one chat-generation wrapper, one
 * embeddings wrapper, and the shared model-JSON parser. Every class-level client seam (drafting,
 * distillation, classification, mining, embedding backfill) delegates here, so the callout ceremony
 * and the response-parsing tolerance change in exactly one place.
 */
public with sharing class EinsteinAiClient {

    // Test hooks: the aiplatform callout cannot run (or be mocked) in test context, so chat()/embed()
    // return these just before the send. Pipeline tests keep mocking their own class-level seams;
    // these exist so this class's own request-building path is exercisable.
    @TestVisible private static String testChatResponse;
    @TestVisible private static List<List<Double>> testEmbedResponse;

    /** One chat generation; returns the first generation's content, or '' on an empty response. */
    public static String chat(String modelName, String prompt) {
        aiplatform.ModelsAPI api = new aiplatform.ModelsAPI();
        aiplatform.ModelsAPI.createChatGenerations_Request req =
            new aiplatform.ModelsAPI.createChatGenerations_Request();
        req.modelName = modelName;

        aiplatform.ModelsAPI_ChatGenerationsRequest body =
            new aiplatform.ModelsAPI_ChatGenerationsRequest();
        req.body = body;

        aiplatform.ModelsAPI_ChatMessageRequest message = new aiplatform.ModelsAPI_ChatMessageRequest();
        message.content = prompt;
        message.role = 'user';
        body.messages = new List<aiplatform.ModelsAPI_ChatMessageRequest>{ message };

        if (Test.isRunningTest()) { return testChatResponse == null ? '' : testChatResponse; }

        aiplatform.ModelsAPI.createChatGenerations_Response resp = api.createChatGenerations(req);
        if (resp.Code200?.generationDetails?.generations != null
                && !resp.Code200.generationDetails.generations.isEmpty()) {
            return resp.Code200.generationDetails.generations[0].content;
        }
        return '';
    }

    /**
     * Batch embeddings; returns one vector per input in order (a failed element stays null), or null
     * when the input is empty or the response carries no embeddings.
     */
    public static List<List<Double>> embed(String modelName, List<String> texts) {
        if (texts == null || texts.isEmpty()) { return null; }
        aiplatform.ModelsAPI api = new aiplatform.ModelsAPI();
        aiplatform.ModelsAPI.createEmbeddings_Request req =
            new aiplatform.ModelsAPI.createEmbeddings_Request();
        req.modelName = modelName;
        aiplatform.ModelsAPI_EmbeddingRequest body = new aiplatform.ModelsAPI_EmbeddingRequest();
        body.input = texts;
        req.body = body;

        if (Test.isRunningTest()) { return testEmbedResponse; }

        aiplatform.ModelsAPI.createEmbeddings_Response resp = api.createEmbeddings(req);
        if (resp?.Code200?.embeddings == null) { return null; }
        List<List<Double>> out = new List<List<Double>>();
        for (Integer k = 0; k < resp.Code200.embeddings.size(); k++) {
            out.add(resp.Code200.embeddings[k] == null ? null : resp.Code200.embeddings[k].embedding);
        }
        return out;
    }

    /**
     * Parse a model reply into its JSON object, tolerating the shapes models actually emit: a bare
     * object (tried FIRST — the payload may legitimately contain a fenced code block that the fence
     * strip would carve out instead), a ```json fenced block, or an object wrapped in prose (the
     * outermost {...} span is carved out). Returns null when no JSON object can be recovered.
     */
    public static Map<String, Object> parseModelJson(String responseBody) {
        if (String.isBlank(responseBody)) { return null; }
        try {
            String txt = responseBody.trim();
            if (txt.startsWith('{')) {
                try {
                    Object direct = JSON.deserializeUntyped(txt);
                    if (direct instanceof Map<String, Object>) { return (Map<String, Object>) direct; }
                } catch (Exception ignored) { /* fall through to fence/carve recovery */ }
            }
            if (txt.contains('```json')) {
                txt = txt.substringAfter('```json').substringBefore('```');
            } else if (txt.contains('```')) {
                txt = txt.substringAfter('```').substringBefore('```');
            }
            txt = txt.trim();
            if (!txt.startsWith('{')) {
                Integer open = txt.indexOf('{');
                Integer close = txt.lastIndexOf('}');
                if (open >= 0 && close > open) { txt = txt.substring(open, close + 1); }
            }
            Object parsed = JSON.deserializeUntyped(txt);
            return (parsed instanceof Map<String, Object>) ? (Map<String, Object>) parsed : null;
        } catch (Exception e) {
            return null;
        }
    }
}
