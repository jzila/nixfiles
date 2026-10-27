"""Delegation backend `model-options`: each delegate_task task may pick a coding model.

The options live in config.yaml, under delegation.backends.model-options.options (set in
modules/hermes-service.nix), each a route in the delegation section's vocabulary (model,
provider, base_url, api_key, request_overrides, reasoning_effort) plus a name and a
description the model reads. A task names one in `model_option`; a task without it takes
the delegation section's own route, as with the default backend.

An option on OpenRouter is refused while OPENROUTER_API_KEY is unset, with a message telling
the model to pick another, instead of a child failing on the missing credential.
"""

from __future__ import annotations

import os
from typing import Any, Mapping

from agent.delegation_provider import DelegationProvider, DelegationRouteError

ROUTE = ("model", "provider", "base_url", "api_key", "request_overrides", "reasoning_effort")


class ModelOptions(DelegationProvider):
    @property
    def name(self) -> str:
        return "model-options"

    @property
    def display_name(self) -> str:
        return "Model options"

    @property
    def summary(self) -> str:
        return "Each subagent task may pick a coding model from delegation.backends.model-options.options."

    def _options(self, config: Mapping[str, Any]) -> list[Mapping[str, Any]]:
        options = self.settings(config).get("options")
        return [o for o in options if isinstance(o, Mapping) and o.get("name")] if isinstance(options, list) else []

    def task_parameters(self, config: Mapping[str, Any]) -> dict[str, dict[str, Any]]:
        options = self._options(config)
        if not options:
            return {}
        return {"model_option": {
            "type": "string",
            "enum": [o["name"] for o in options],
            "description": "The model this task runs on; omit for the usual one. "
            + " ".join(f"{o['name']}: {o.get('description', '')}" for o in options),
        }}

    def description(self, config: Mapping[str, Any]) -> str:
        return "Each task may set `model_option` to choose its model (see that parameter)." if self._options(config) else ""

    def route_task(self, task: Mapping[str, Any], config: Mapping[str, Any]) -> dict[str, Any]:
        chosen = task.get("model_option")
        if not chosen:
            # The delegation section's route, as the default backend takes it.
            return {k: v for k, v in config.items() if k not in ("backend", "backends", "service_tier")}
        for option in self._options(config):
            if option["name"] != chosen:
                continue
            if option.get("provider") == "openrouter" and not os.environ.get("OPENROUTER_API_KEY"):
                raise DelegationRouteError(
                    f"model_option '{chosen}' needs OpenRouter, which has no API key yet; "
                    "resend the task with another model_option or none.")
            route = {k: option[k] for k in ROUTE if k in option}
            route["label"] = chosen
            return route
        raise DelegationRouteError(f"unknown model_option '{chosen}'; omit it or pick one of the listed values.")


def register(ctx) -> None:
    ctx.register_delegation_provider(ModelOptions())
