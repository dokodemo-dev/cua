// SPDX-License-Identifier: FSL-1.1-MIT

package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
)

type chatBody struct {
	Prompt string `json:"prompt"`
}

// chatRoute is the browser's window on the Bot: POST sends a turn, GET reads
// the turns after an index.
func (s *Service) chatRoute(botID string, r *http.Request, body []byte) (int, any) {
	switch r.Method {
	case http.MethodPost:
		var in chatBody
		if err := json.Unmarshal(body, &in); err != nil {
			return http.StatusBadRequest, map[string]string{"error": "malformed request"}
		}
		if len(in.Prompt) > 8*1024 {
			return http.StatusRequestEntityTooLarge, map[string]string{"error": "prompt too long"}
		}
		turn, err := s.chat.Start(botID, in.Prompt)
		switch {
		case errors.Is(err, ErrEmptyPrompt):
			return http.StatusBadRequest, map[string]string{"error": err.Error()}
		case errors.Is(err, ErrChatBusy):
			return http.StatusTooManyRequests, map[string]string{"error": err.Error()}
		case err != nil:
			return http.StatusInternalServerError, map[string]string{"error": "turn not started"}
		}
		return http.StatusAccepted, map[string]any{"turn": turn}
	case http.MethodGet:
		after := 0
		if v := r.URL.Query().Get("after"); v != "" {
			n, err := strconv.Atoi(v)
			if err != nil || n < 0 {
				return http.StatusBadRequest, map[string]string{"error": "bad cursor"}
			}
			after = n
		}
		turns, next := s.chat.List(botID, after)
		return http.StatusOK, map[string]any{"turns": turns, "next": next}
	default:
		return http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"}
	}
}
