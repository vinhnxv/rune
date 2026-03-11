"""Figma API type definitions for the figma-to-react MCP server.

Pydantic v2 models representing Figma REST API response structures.
Covers the 12 core node types, paint/effect/typography styles, and
auto-layout v5 properties. All models use ``extra="ignore"`` to
safely parse partial API responses without failing on unknown fields.

Reference: https://www.figma.com/developers/api#node-types
"""

from __future__ import annotations

from enum import Enum
from typing import Any, Dict, List, Optional, Union

from pydantic import BaseModel, ConfigDict, Field


# ---------------------------------------------------------------------------
# Enumerations
# ---------------------------------------------------------------------------


class NodeType(str, Enum):
    """Figma node types supported by the parser.

    Unsupported types (STICKY, CONNECTOR, TABLE, etc.) are handled
    gracefully by the node parser -- they are skipped with a warning.
    """

    FRAME = "FRAME"
    TEXT = "TEXT"
    RECTANGLE = "RECTANGLE"
    ELLIPSE = "ELLIPSE"
    GROUP = "GROUP"
    COMPONENT = "COMPONENT"
    INSTANCE = "INSTANCE"
    COMPONENT_SET = "COMPONENT_SET"
    SECTION = "SECTION"
    VECTOR = "VECTOR"
    BOOLEAN_OPERATION = "BOOLEAN_OPERATION"
    LINE = "LINE"
    REGULAR_POLYGON = "REGULAR_POLYGON"
    STAR = "STAR"
    # Not a real Figma type -- used internally to tag nodes with image fills
    IMAGE_FILL = "IMAGE_FILL"


class PaintType(str, Enum):
    """Figma paint (fill/stroke) types."""

    SOLID = "SOLID"
    GRADIENT_LINEAR = "GRADIENT_LINEAR"
    GRADIENT_RADIAL = "GRADIENT_RADIAL"
    GRADIENT_ANGULAR = "GRADIENT_ANGULAR"
    GRADIENT_DIAMOND = "GRADIENT_DIAMOND"
    IMAGE = "IMAGE"


class EffectType(str, Enum):
    """Figma effect types."""

    DROP_SHADOW = "DROP_SHADOW"
    INNER_SHADOW = "INNER_SHADOW"
    LAYER_BLUR = "LAYER_BLUR"
    BACKGROUND_BLUR = "BACKGROUND_BLUR"


class BlendMode(str, Enum):
    """Common blend modes used in Figma."""

    PASS_THROUGH = "PASS_THROUGH"
    NORMAL = "NORMAL"
    DARKEN = "DARKEN"
    MULTIPLY = "MULTIPLY"
    LINEAR_BURN = "LINEAR_BURN"
    COLOR_BURN = "COLOR_BURN"
    LIGHTEN = "LIGHTEN"
    SCREEN = "SCREEN"
    LINEAR_DODGE = "LINEAR_DODGE"
    COLOR_DODGE = "COLOR_DODGE"
    OVERLAY = "OVERLAY"
    SOFT_LIGHT = "SOFT_LIGHT"
    HARD_LIGHT = "HARD_LIGHT"
    DIFFERENCE = "DIFFERENCE"
    EXCLUSION = "EXCLUSION"
    HUE = "HUE"
    SATURATION = "SATURATION"
    COLOR = "COLOR"
    LUMINOSITY = "LUMINOSITY"


class LayoutMode(str, Enum):
    """Auto-layout direction modes."""

    NONE = "NONE"
    HORIZONTAL = "HORIZONTAL"
    VERTICAL = "VERTICAL"


class LayoutWrap(str, Enum):
    """Auto-layout wrap behavior (v5)."""

    NO_WRAP = "NO_WRAP"
    WRAP = "WRAP"


class LayoutAlign(str, Enum):
    """Auto-layout primary/counter axis alignment."""

    MIN = "MIN"
    CENTER = "CENTER"
    MAX = "MAX"
    SPACE_BETWEEN = "SPACE_BETWEEN"
    BASELINE = "BASELINE"
    AUTO = "AUTO"


class LayoutSizingMode(str, Enum):
    """How a child sizes itself within auto-layout."""

    FIXED = "FIXED"
    HUG = "HUG"
    FILL = "FILL"


class TextAutoResize(str, Enum):
    """How text layers resize."""

    NONE = "NONE"
    HEIGHT = "HEIGHT"
    WIDTH_AND_HEIGHT = "WIDTH_AND_HEIGHT"
    TRUNCATE = "TRUNCATE"


class TextAlignHorizontal(str, Enum):
    """Horizontal text alignment."""

    LEFT = "LEFT"
    CENTER = "CENTER"
    RIGHT = "RIGHT"
    JUSTIFIED = "JUSTIFIED"


class TextAlignVertical(str, Enum):
    """Vertical text alignment."""

    TOP = "TOP"
    CENTER = "CENTER"
    BOTTOM = "BOTTOM"


class StrokeAlign(str, Enum):
    """Stroke alignment relative to the node boundary."""

    INSIDE = "INSIDE"
    OUTSIDE = "OUTSIDE"
    CENTER = "CENTER"


class BooleanOperationType(str, Enum):
    """Boolean operation types for BOOLEAN_OPERATION nodes."""

    UNION = "UNION"
    INTERSECT = "INTERSECT"
    SUBTRACT = "SUBTRACT"
    EXCLUDE = "EXCLUDE"


class FigmaPropertyType(str, Enum):
    """Component property types from the Figma REST API.

    Reference: https://github.com/figma/rest-api-spec/blob/main/dist/api_types.ts
    """

    BOOLEAN = "BOOLEAN"
    INSTANCE_SWAP = "INSTANCE_SWAP"
    TEXT = "TEXT"
    VARIANT = "VARIANT"


class ConstraintType(str, Enum):
    """Constraint types for absolute positioning.

    The Figma API returns both abstract names (MIN, MAX, STRETCH) and
    positional names (TOP, BOTTOM, LEFT, RIGHT, TOP_BOTTOM, LEFT_RIGHT).
    Both conventions must be supported for robust parsing.
    """

    # Abstract names (legacy docs)
    MIN = "MIN"
    CENTER = "CENTER"
    MAX = "MAX"
    STRETCH = "STRETCH"
    SCALE = "SCALE"
    # Positional names (returned by current API)
    TOP = "TOP"
    BOTTOM = "BOTTOM"
    LEFT = "LEFT"
    RIGHT = "RIGHT"
    TOP_BOTTOM = "TOP_BOTTOM"
    LEFT_RIGHT = "LEFT_RIGHT"


# ---------------------------------------------------------------------------
# Value types
# ---------------------------------------------------------------------------


class Color(BaseModel):
    """RGBA color value (0.0-1.0 range)."""

    model_config = ConfigDict(extra="ignore")

    r: float = 0.0
    g: float = 0.0
    b: float = 0.0
    a: float = 1.0

    def to_hex(self) -> str:
        """Convert to CSS hex string (#RRGGBB or #RRGGBBAA)."""
        r = max(0, min(255, round(self.r * 255)))
        g = max(0, min(255, round(self.g * 255)))
        b = max(0, min(255, round(self.b * 255)))
        if self.a < 1.0:
            a = max(0, min(255, round(self.a * 255)))
            return f"#{r:02x}{g:02x}{b:02x}{a:02x}"
        return f"#{r:02x}{g:02x}{b:02x}"


class Vector2D(BaseModel):
    """2D vector used for positions, sizes, and gradient handles."""

    model_config = ConfigDict(extra="ignore")

    x: float = 0.0
    y: float = 0.0


class Rectangle(BaseModel):
    """Bounding rectangle."""

    model_config = ConfigDict(extra="ignore")

    x: float = 0.0
    y: float = 0.0
    width: float = 0.0
    height: float = 0.0


class Constraints(BaseModel):
    """Layout constraints for absolute positioning."""

    model_config = ConfigDict(extra="ignore")

    vertical: ConstraintType = ConstraintType.MIN
    horizontal: ConstraintType = ConstraintType.MIN


class ColorStop(BaseModel):
    """A single color stop in a gradient."""

    model_config = ConfigDict(extra="ignore")

    position: float = 0.0
    color: Color = Field(default_factory=Color)


# ---------------------------------------------------------------------------
# Paint / Effect / TypeStyle models
# ---------------------------------------------------------------------------


class Paint(BaseModel):
    """Fill or stroke paint definition.

    Covers SOLID colors, linear/radial/angular/diamond gradients,
    and IMAGE fills. The ``type`` field discriminates between them.
    """

    model_config = ConfigDict(extra="ignore")

    type: PaintType = PaintType.SOLID
    visible: bool = True
    opacity: float = 1.0
    color: Optional[Color] = None
    blend_mode: Optional[BlendMode] = Field(default=None, alias="blendMode")

    # Gradient fields
    gradient_handle_positions: Optional[List[Vector2D]] = Field(
        default=None, alias="gradientHandlePositions"
    )
    gradient_stops: Optional[List[ColorStop]] = Field(
        default=None, alias="gradientStops"
    )

    # Image fill fields
    scale_mode: Optional[str] = Field(default=None, alias="scaleMode")
    image_ref: Optional[str] = Field(default=None, alias="imageRef")
    image_transform: Optional[List[List[float]]] = Field(
        default=None, alias="imageTransform"
    )


class Effect(BaseModel):
    """Visual effect (shadow or blur).

    DROP_SHADOW and INNER_SHADOW include offset, radius, spread, and color.
    LAYER_BLUR and BACKGROUND_BLUR only use radius.
    """

    model_config = ConfigDict(extra="ignore")

    type: EffectType
    visible: bool = True
    radius: float = 0.0
    color: Optional[Color] = None
    blend_mode: Optional[BlendMode] = Field(default=None, alias="blendMode")
    offset: Optional[Vector2D] = None
    spread: float = 0.0
    show_shadow_behind_node: Optional[bool] = Field(
        default=None, alias="showShadowBehindNode"
    )


class TypeStyle(BaseModel):
    """Typography style properties.

    Represents the full set of text styling applied to a TEXT node
    or a style override segment within one.
    """

    model_config = ConfigDict(extra="ignore")

    font_family: Optional[str] = Field(default=None, alias="fontFamily")
    font_post_script_name: Optional[str] = Field(
        default=None, alias="fontPostScriptName"
    )
    font_weight: Optional[float] = Field(default=None, alias="fontWeight")
    font_size: Optional[float] = Field(default=None, alias="fontSize")
    text_align_horizontal: Optional[TextAlignHorizontal] = Field(
        default=None, alias="textAlignHorizontal"
    )
    text_align_vertical: Optional[TextAlignVertical] = Field(
        default=None, alias="textAlignVertical"
    )
    letter_spacing: Optional[float] = Field(default=None, alias="letterSpacing")
    line_height_px: Optional[float] = Field(default=None, alias="lineHeightPx")
    line_height_percent: Optional[float] = Field(
        default=None, alias="lineHeightPercent"
    )
    line_height_unit: Optional[str] = Field(default=None, alias="lineHeightUnit")
    text_decoration: Optional[str] = Field(default=None, alias="textDecoration")
    text_case: Optional[str] = Field(default=None, alias="textCase")
    italic: Optional[bool] = None
    fills: Optional[List[Paint]] = None
    opacity: Optional[float] = None


# ---------------------------------------------------------------------------
# Auto-layout properties (v4/v5)
# ---------------------------------------------------------------------------


class AutoLayoutProperties(BaseModel):
    """Auto-layout properties for FRAME-like nodes.

    Covers v4 basics (direction, gap, padding) and v5 additions
    (min/max dimensions, wrap mode, grid layout).
    """

    model_config = ConfigDict(extra="ignore")

    layout_mode: LayoutMode = Field(default=LayoutMode.NONE, alias="layoutMode")
    layout_wrap: LayoutWrap = Field(default=LayoutWrap.NO_WRAP, alias="layoutWrap")

    # Alignment
    primary_axis_align_items: Optional[LayoutAlign] = Field(
        default=None, alias="primaryAxisAlignItems"
    )
    counter_axis_align_items: Optional[LayoutAlign] = Field(
        default=None, alias="counterAxisAlignItems"
    )
    counter_axis_align_content: Optional[LayoutAlign] = Field(
        default=None, alias="counterAxisAlignContent"
    )

    # Sizing
    primary_axis_sizing_mode: Optional[LayoutSizingMode] = Field(
        default=None, alias="primaryAxisSizingMode"
    )
    counter_axis_sizing_mode: Optional[LayoutSizingMode] = Field(
        default=None, alias="counterAxisSizingMode"
    )
    layout_sizing_horizontal: Optional[LayoutSizingMode] = Field(
        default=None, alias="layoutSizingHorizontal"
    )
    layout_sizing_vertical: Optional[LayoutSizingMode] = Field(
        default=None, alias="layoutSizingVertical"
    )

    # Spacing
    item_spacing: float = Field(default=0.0, alias="itemSpacing")
    counter_axis_spacing: Optional[float] = Field(
        default=None, alias="counterAxisSpacing"
    )
    padding_left: float = Field(default=0.0, alias="paddingLeft")
    padding_right: float = Field(default=0.0, alias="paddingRight")
    padding_top: float = Field(default=0.0, alias="paddingTop")
    padding_bottom: float = Field(default=0.0, alias="paddingBottom")

    # v5 min/max constraints
    min_width: Optional[float] = Field(default=None, alias="minWidth")
    max_width: Optional[float] = Field(default=None, alias="maxWidth")
    min_height: Optional[float] = Field(default=None, alias="minHeight")
    max_height: Optional[float] = Field(default=None, alias="maxHeight")

    # Grid mode (auto-layout v5)
    layout_grid_columns: Optional[int] = Field(
        default=None, alias="layoutGridColumns"
    )
    layout_grid_cell_min_width: Optional[float] = Field(
        default=None, alias="layoutGridCellMinWidth"
    )


# ---------------------------------------------------------------------------
# Component property models
# ---------------------------------------------------------------------------


class InstanceSwapPreferredValue(BaseModel):
    """Preferred value for INSTANCE_SWAP properties."""

    model_config = ConfigDict(extra="ignore")

    type: str = ""  # "COMPONENT" or "COMPONENT_SET"
    key: str = ""


class ComponentPropertyDefinition(BaseModel):
    """Schema definition for a component property.

    Found on COMPONENT and COMPONENT_SET nodes under
    ``componentPropertyDefinitions``.
    """

    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    type: FigmaPropertyType
    default_value: Union[bool, str] = Field(alias="defaultValue")
    variant_options: Optional[List[str]] = Field(
        None, alias="variantOptions"
    )
    preferred_values: Optional[List[InstanceSwapPreferredValue]] = Field(
        None, alias="preferredValues"
    )


class ComponentProperty(BaseModel):
    """Override value for a component property on INSTANCE nodes.

    Found under ``componentProperties``.
    """

    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    type: FigmaPropertyType
    value: Union[bool, str]
    preferred_values: Optional[List[InstanceSwapPreferredValue]] = Field(
        None, alias="preferredValues"
    )
    bound_variables: Optional[Dict[str, Any]] = Field(
        None, alias="boundVariables"
    )


# ---------------------------------------------------------------------------
# Node models
# ---------------------------------------------------------------------------


class FigmaNodeBase(BaseModel):
    """Base model for all Figma node types.

    Contains fields common to every node in the Figma document tree.
    Specific node types extend this with their own fields.
    """

    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    id: str
    name: str = ""
    type: str = ""
    visible: bool = True
    opacity: Optional[float] = None
    blend_mode: Optional[BlendMode] = Field(default=None, alias="blendMode")
    rotation: Optional[float] = None

    # Geometry
    absolute_bounding_box: Optional[Rectangle] = Field(
        default=None, alias="absoluteBoundingBox"
    )
    absolute_render_bounds: Optional[Rectangle] = Field(
        default=None, alias="absoluteRenderBounds"
    )
    size: Optional[Vector2D] = None
    relative_transform: Optional[List[List[float]]] = Field(
        default=None, alias="relativeTransform"
    )
    constraints: Optional[Constraints] = None

    # Styling
    fills: List[Paint] = Field(default_factory=list)
    strokes: List[Paint] = Field(default_factory=list)
    stroke_weight: Optional[float] = Field(default=None, alias="strokeWeight")
    stroke_align: Optional[StrokeAlign] = Field(default=None, alias="strokeAlign")
    effects: List[Effect] = Field(default_factory=list)
    corner_radius: Optional[float] = Field(default=None, alias="cornerRadius")
    rectangle_corner_radii: Optional[List[float]] = Field(
        default=None, alias="rectangleCornerRadii"
    )

    # Layout
    layout_align: Optional[str] = Field(default=None, alias="layoutAlign")
    layout_grow: Optional[float] = Field(default=None, alias="layoutGrow")
    layout_positioning: Optional[str] = Field(
        default=None, alias="layoutPositioning"
    )
    layout_sizing_horizontal: Optional[LayoutSizingMode] = Field(
        default=None, alias="layoutSizingHorizontal"
    )
    layout_sizing_vertical: Optional[LayoutSizingMode] = Field(
        default=None, alias="layoutSizingVertical"
    )

    # Children
    children: List[FigmaNodeBase] = Field(default_factory=list)

    # Component references
    component_id: Optional[str] = Field(default=None, alias="componentId")

    # Component property definitions (on COMPONENT and COMPONENT_SET nodes)
    component_property_definitions: Optional[
        Dict[str, ComponentPropertyDefinition]
    ] = Field(default=None, alias="componentPropertyDefinitions")

    # Component property override values (on INSTANCE nodes)
    component_properties: Optional[Dict[str, ComponentProperty]] = Field(
        default=None, alias="componentProperties"
    )

    # Export settings (for detecting image exports)
    export_settings: Optional[List[Dict[str, Any]]] = Field(
        default=None, alias="exportSettings"
    )


class FrameNode(FigmaNodeBase):
    """FRAME, COMPONENT, INSTANCE, COMPONENT_SET, or SECTION node.

    These share auto-layout and clipping properties.
    """

    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    clips_content: bool = Field(default=False, alias="clipsContent")
    # Auto-layout (inlined for simpler parsing)
    layout_mode: Optional[LayoutMode] = Field(default=None, alias="layoutMode")
    layout_wrap: Optional[LayoutWrap] = Field(default=None, alias="layoutWrap")
    primary_axis_align_items: Optional[LayoutAlign] = Field(
        default=None, alias="primaryAxisAlignItems"
    )
    counter_axis_align_items: Optional[LayoutAlign] = Field(
        default=None, alias="counterAxisAlignItems"
    )
    counter_axis_align_content: Optional[LayoutAlign] = Field(
        default=None, alias="counterAxisAlignContent"
    )
    primary_axis_sizing_mode: Optional[LayoutSizingMode] = Field(
        default=None, alias="primaryAxisSizingMode"
    )
    counter_axis_sizing_mode: Optional[LayoutSizingMode] = Field(
        default=None, alias="counterAxisSizingMode"
    )
    item_spacing: Optional[float] = Field(default=None, alias="itemSpacing")
    counter_axis_spacing: Optional[float] = Field(
        default=None, alias="counterAxisSpacing"
    )
    padding_left: float = Field(default=0.0, alias="paddingLeft")
    padding_right: float = Field(default=0.0, alias="paddingRight")
    padding_top: float = Field(default=0.0, alias="paddingTop")
    padding_bottom: float = Field(default=0.0, alias="paddingBottom")
    min_width: Optional[float] = Field(default=None, alias="minWidth")
    max_width: Optional[float] = Field(default=None, alias="maxWidth")
    min_height: Optional[float] = Field(default=None, alias="minHeight")
    max_height: Optional[float] = Field(default=None, alias="maxHeight")
    layout_grid_columns: Optional[int] = Field(
        default=None, alias="layoutGridColumns"
    )
    layout_grid_cell_min_width: Optional[float] = Field(
        default=None, alias="layoutGridCellMinWidth"
    )


class TextNode(FigmaNodeBase):
    """TEXT node with typography and styled segments."""

    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    characters: str = ""
    style: Optional[TypeStyle] = None
    character_style_overrides: Optional[List[int]] = Field(
        default=None, alias="characterStyleOverrides"
    )
    style_override_table: Optional[Dict[str, TypeStyle]] = Field(
        default=None, alias="styleOverrideTable"
    )
    text_auto_resize: Optional[TextAutoResize] = Field(
        default=None, alias="textAutoResize"
    )
    line_types: Optional[List[str]] = Field(default=None, alias="lineTypes")
    line_indentations: Optional[List[float]] = Field(
        default=None, alias="lineIndentations"
    )


class BooleanOperationNode(FigmaNodeBase):
    """BOOLEAN_OPERATION node (union, intersect, subtract, exclude)."""

    model_config = ConfigDict(extra="ignore", populate_by_name=True)

    boolean_operation: Optional[BooleanOperationType] = Field(
        default=None, alias="booleanOperation"
    )


# ---------------------------------------------------------------------------
# API response wrappers
# ---------------------------------------------------------------------------


class FigmaFileResponse(BaseModel):
    """Top-level response from GET /v1/files/{key}."""

    model_config = ConfigDict(extra="ignore")

    name: str = ""
    last_modified: Optional[str] = Field(default=None, alias="lastModified")
    thumbnail_url: Optional[str] = Field(default=None, alias="thumbnailUrl")
    version: Optional[str] = None
    document: Optional[FigmaNodeBase] = None
    schema_version: Optional[int] = Field(default=None, alias="schemaVersion")


class FigmaNodeData(BaseModel):
    """Wrapper for individual node data in /nodes response."""

    model_config = ConfigDict(extra="ignore")

    document: Optional[FigmaNodeBase] = None
    components: Dict[str, Any] = Field(default_factory=dict)
    schema_version: Optional[int] = Field(default=None, alias="schemaVersion")


class FigmaNodesResponse(BaseModel):
    """Response from GET /v1/files/{key}/nodes?ids=...."""

    model_config = ConfigDict(extra="ignore")

    name: str = ""
    last_modified: Optional[str] = Field(default=None, alias="lastModified")
    nodes: Dict[str, Optional[FigmaNodeData]] = Field(default_factory=dict)


class FigmaImageResponse(BaseModel):
    """Response from GET /v1/images/{key}."""

    model_config = ConfigDict(extra="ignore")

    err: Optional[str] = None
    images: Dict[str, Optional[str]] = Field(default_factory=dict)


# ---------------------------------------------------------------------------
# Forward references
# ---------------------------------------------------------------------------

# Pydantic v2 requires model_rebuild() for self-referencing models
FigmaNodeBase.model_rebuild()
FrameNode.model_rebuild()
TextNode.model_rebuild()
BooleanOperationNode.model_rebuild()
FigmaNodesResponse.model_rebuild()
