;; -*- lexical-binding: t; -*-

;; Emacboros --- gptel configuration
;; Copyright (C) 2026 Ignacio Agustín Randazzo
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.


(defvar emacboros-ollama-host nil
  "Ollama API host. Set from EMACBOROS_OLLAMA_HOST env var or defaults to remote.")

;; Determine Ollama host: check environment variable first, fall back to remote default.
(setq emacboros-ollama-host
      (or (getenv "EMACBOROS_OLLAMA_HOST")
          "10.66.0.5:11434"))

(setq emacboros-gptel-backend
      (gptel-make-ollama "Ollama"
                         :host emacboros-ollama-host
                         :stream t
                         :models '("north-mini-code-1.0:q8_0"
                                   "granite4.1:8b-q8_0"
                                   "gpt-oss:20b"
                                   "gpt-oss:120b"
                                   "mistral-medium-3.5:128b"
                                   "nemotron-3-super:120b"
                                   "nemotron-3-ultra:cloud"
                                   "glm-5.2:cloud")
                         :request-params '(:options (
                                          :temperature 0.7
                                          :top_p 0.95
                                          :num_ctx 1048576
                                          :num_predict 65536
                                        ))))


(setq emacboros-gptel-default-model 'nemotron-3-ultra:cloud)
