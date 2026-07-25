
## Voiceprint Matching Fixes
- Fixed a bug where `saveEmbeddingForSpeaker` would use a random speaker's embedding if the exact speaker label was not found. This caused voiceprints to be incorrectly assigned to contacts (e.g. "matched wrong").
- Fixed a bug where exiting the meeting to save new temporary speakers ("Speaker_X") to the contact directory did not actually save their voiceprint embeddings. This caused the new contacts to have no voiceprint (e.g. "didn't match").
- Adjusted `matchingThreshold` to 0.55 and `highConfidenceThreshold` to 0.60 to better align with the clustering distance (0.45, similarity 0.55) of the Sherpa-ONNX model.

## UI Fixes
- Fixed the `MeetingInfoSidebar` filter not updating when a temporary speaker currently being filtered is renamed to a known contact.
- Fixed `ReviewingView`'s bubble speaker rename so that renaming a temporary speaker ("Speaker_X") globally renames them, just like in `RecordingView`.
- Fixed the multiline `TextField` layout in `UnifiedTranscriptEditor` on macOS by using a hidden `Text` view to correctly drive the height constraints.
