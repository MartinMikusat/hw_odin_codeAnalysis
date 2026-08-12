# Odin Code Analysis TODO

## Active

- [ ] Add persistent query indexes.
  - Build owned indexes by package directory, file, symbol name, owner type, and symbol identifier inside each private candidate generation.
  - Publish the indexes with the existing atomic generation swap.
  - Completion: definition, reference, completion, caller, callee, and search queries use the indexes instead of scanning complete symbol and file collections, with unchanged query results on the existing fixtures.

- [ ] Complete semantic and daemon coverage.
  - Add fixtures for nested shadowing, sibling procedures, and ambiguous fields.
  - Add a daemon test for files deleted during rebuild.
  - Decode integration-test JSON and assert typed fields instead of matching shell substrings.
  - Completion: the new semantic fixtures return the expected resolution kind and locations, deletion publishes a complete replacement generation without stale results, and integration failures identify the mismatched JSON field.
