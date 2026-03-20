"""
Agent schema validation for the Agent Search MCP server.

Validates agent registration inputs against naming, size, and content rules
before persisting to the index.
"""

import re
from typing import Any, List, Optional

# SEC-5: Agent name allowlist — lowercase letter start, lowercase + hyphens + digits
# Plan requirement: /^[a-z][a-z0-9-]+$/ — no uppercase, no underscores
VALID_NAME_RE = re.compile(r'^[a-z][a-z0-9-]+$')

# Constraints
MAX_NAME_LENGTH = 128
MAX_DESCRIPTION_LENGTH = 10000
MAX_BODY_LENGTH = 100000
MAX_TAG_LENGTH = 128
MAX_TAGS_COUNT = 50

# Valid source values
VALID_SOURCES = frozenset({"builtin", "extended", "project", "user"})

# Valid categories
VALID_CATEGORIES = frozenset({
    "review", "investigation", "research", "work",
    "utility", "testing", "unknown",
})


def _validate_name(name: Any, errors: List[str]) -> None:
    """Validate agent name field.

    Args:
        name: Agent name value to validate.
        errors: Error list to append to.
    """
    if not name or not isinstance(name, str):
        errors.append("name is required and must be a non-empty string")
    elif len(name) > MAX_NAME_LENGTH:
        errors.append("name exceeds %d character limit" % MAX_NAME_LENGTH)
    elif not VALID_NAME_RE.match(name):
        errors.append(
            "name must start with a lowercase letter and contain "
            "only lowercase letters, digits, and hyphens"
        )


def _validate_description(
    description: Any, source: str, errors: List[str]
) -> None:
    """Validate agent description field.

    Args:
        description: Agent description value to validate.
        source: Source category (affects minimum length rule).
        errors: Error list to append to.
    """
    if not description or not isinstance(description, str):
        errors.append("description is required and must be a non-empty string")
    elif len(description) < 20 and source == "user":
        errors.append(
            "description must be at least 20 characters for user agents"
        )
    elif len(description) > MAX_DESCRIPTION_LENGTH:
        errors.append(
            "description exceeds %d character limit" % MAX_DESCRIPTION_LENGTH
        )


_VALID_TAG_RE = re.compile(r'^[a-z0-9:._\-/]+$')


def _validate_tags(tags: Any, errors: List[str]) -> None:
    """Validate agent tags field.

    Args:
        tags: Tags list value to validate.
        errors: Error list to append to.
    """
    if tags is None:
        return
    if not isinstance(tags, list):
        errors.append("tags must be a list of strings")
    elif len(tags) > MAX_TAGS_COUNT:
        errors.append("tags exceed %d item limit" % MAX_TAGS_COUNT)
    else:
        for i, tag in enumerate(tags):
            if not isinstance(tag, str):
                errors.append("tags[%d] must be a string" % i)
            elif len(tag) > MAX_TAG_LENGTH:
                errors.append(
                    "tags[%d] exceeds %d character limit"
                    % (i, MAX_TAG_LENGTH)
                )
            elif not _VALID_TAG_RE.match(tag):
                errors.append(
                    "tags[%d] contains invalid characters — "
                    "only lowercase letters, digits, colons, dots, "
                    "hyphens, underscores, and slashes allowed" % i
                )


def _validate_body(body: Any, errors: List[str]) -> None:
    """Validate agent body field.

    Args:
        body: Body markdown value to validate.
        errors: Error list to append to.
    """
    if body is None:
        return
    if not isinstance(body, str):
        errors.append("body must be a string")
    elif len(body) > MAX_BODY_LENGTH:
        errors.append(
            "body exceeds %d character limit" % MAX_BODY_LENGTH
        )


def validate_agent_schema(
    name: Any,
    description: Any,
    source: str = "user",
    category: Optional[Any] = None,
    tags: Optional[Any] = None,
    body: Optional[Any] = None,
) -> List[str]:
    """Validate agent registration inputs.

    Checks naming conventions, size limits, and content rules.
    Returns an empty list on success, or a list of error strings.

    Args:
        name: Agent name (required).
        description: Agent description (required).
        source: Source category (default "user").
        category: Optional category string.
        tags: Optional list of tag strings.
        body: Optional body markdown.

    Returns:
        List of validation error strings. Empty means valid.
    """
    errors: List[str] = []

    _validate_name(name, errors)
    _validate_description(description, source, errors)

    # --- Source validation ---
    if source not in VALID_SOURCES:
        errors.append(
            "source must be one of: %s" % ", ".join(sorted(VALID_SOURCES))
        )

    # --- Category validation ---
    if category is not None:
        if not isinstance(category, str):
            errors.append("category must be a string")
        elif category.lower() not in VALID_CATEGORIES:
            errors.append(
                "category must be one of: %s"
                % ", ".join(sorted(VALID_CATEGORIES))
            )

    _validate_tags(tags, errors)
    _validate_body(body, errors)

    return errors
