---
description: When working in the omicron repo, answer a question about how Oxide's external API works
---

# Oxide external API Q&A

When answering a question about how something works in the API, look at relevant code by following the call chain down from the handlers of the relevant endpoints.

## Key paths

* Start with `nexus/external-api/output/nexus_tags.txt`, a concise list of all API endpoints, to find the operation IDs and then grep for them in the other files. Helpful because the other files are very big.
* `nexus/external-api/src/lib.rs`: Dropshot API trait definition showing paths, operation IDs, and request body, response body, and query param types
* `nexus/src/external_api/http_entrypoints.rs`: endpoint handler definitions
* `openapi/nexus/nexus-latest.json`: symlink to current API schema. The schema is huge, beware.
* `nexus/tests/integration_tests`: you may need to look at integration tests to verify certain behaviors
