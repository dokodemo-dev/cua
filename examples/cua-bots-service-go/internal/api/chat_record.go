// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"encoding/json"
	"net/http"
)

type recordBody struct {
	Prompt string `json:"prompt"`
	Output string `json:"output"`
	Status string `json:"status"`
}

// chatRecord files a turn that ran outside the service (the scheduler's
// routine) so it appears in the same window. It is not a way to run anything.
func (s *Service) chatRecord(botID string, body []byte) (int, any) {
	var in recordBody
	if err := json.Unmarshal(body, &in); err != nil {
		return http.StatusBadRequest, map[string]string{"error": "malformed request"}
	}
	if len(in.Output) > maxOutput {
		in.Output = in.Output[len(in.Output)-maxOutput:]
	}
	turn := s.chat.Record(botID, in.Prompt, in.Output, in.Status)
	if turn.ID == "" {
		return http.StatusConflict, map[string]string{"error": "a turn is running for this bot"}
	}
	return http.StatusCreated, map[string]any{"turn": turn}
}
