#!/usr/bin/env python3
"""Build a deployment checkpoint with Curriculum LoRA Stacking.

The OpenPI pi0.5 checkpoints used in this project store full model parameters
plus LoRA factors.  This script implements the paper rule

    W(alpha) = W0 + sum_i alpha_i Delta W_i

by materializing each LoRA factor pair into its dense update, summing the
updates in weight space, writing the result into the dense weights, and zeroing
the LoRA factors in the output checkpoint.  The output keeps OpenPI's normal
checkpoint layout:

    <output_checkpoint>/
      params/
      assets/
      lora_stacking_manifest.json

Example:

    PYTHONPATH=/path/to/openpi/src:/path/to/repo \
      python -m recoverable_vla_lora_stacking.lora_stacking \
      --adapter stage2=/path/to/stage2/50000/params \
      --adapter stage3=/path/to/stage3/49999/params \
      --adapter stage4=/path/to/stage4/49999/params \
      --alpha stage2=0.45 --alpha stage3=0.35 --alpha stage4=0.20 \
      --adapter-mode sequential-delta \
      --output-checkpoint /path/to/stacked_checkpoint

Use ``--adapter-mode sequential-delta`` when the listed adapters are continuation
snapshots and stage deltas should be recovered as [A2, A3-A2, A4-A3].
Use ``--adapter-mode independent`` only when each listed path already contains
one independently exported stage adapter on the same base.
"""

from __future__ import annotations

import argparse
from collections.abc import Iterable, Mapping, MutableMapping, Sequence
import dataclasses
import datetime as dt
import json
from pathlib import Path
import shutil
from typing import Any, Literal

import numpy as np


PathKey = tuple[Any, ...]
AdapterMode = Literal["independent", "sequential-delta"]


@dataclasses.dataclass(frozen=True)
class AdapterSpec:
    name: str
    params_path: Path
    alpha: float


@dataclasses.dataclass(frozen=True)
class LoRAModule:
    base_key: PathKey
    a_key: PathKey
    b_key: PathKey
    kind: str


LORA_A_TO_BASE = {
    "lora_a": ("lora_b", "w"),
    "gating_einsum_lora_a": ("gating_einsum_lora_b", "gating_einsum"),
    "linear_lora_a": ("linear_lora_b", "linear"),
}


def flatten_tree(tree: Mapping[Any, Any], prefix: PathKey = ()) -> dict[PathKey, Any]:
    flat: dict[PathKey, Any] = {}
    for key, value in tree.items():
        path = (*prefix, key)
        if isinstance(value, Mapping):
            flat.update(flatten_tree(value, path))
        else:
            flat[path] = value
    return flat


def unflatten_tree(flat: Mapping[PathKey, Any]) -> dict[Any, Any]:
    root: dict[Any, Any] = {}
    for path, value in flat.items():
        cursor: MutableMapping[Any, Any] = root
        for part in path[:-1]:
            cursor = cursor.setdefault(part, {})
        cursor[path[-1]] = value
    return root


def format_key(key: PathKey) -> str:
    return "/".join(str(part) for part in key)


def dense_lora_update(a: Any, b: Any) -> np.ndarray:
    """Return the dense update represented by OpenPI LoRA factors A and B."""
    a_arr = np.asarray(a, dtype=np.float32)
    b_arr = np.asarray(b, dtype=np.float32)
    if a_arr.ndim < 2 or b_arr.ndim < 2:
        raise ValueError(f"LoRA factors must be at least 2D, got {a_arr.shape} and {b_arr.shape}")
    if a_arr.shape[:-2] != b_arr.shape[:-2]:
        raise ValueError(f"LoRA factors have incompatible prefixes: {a_arr.shape} vs {b_arr.shape}")
    if a_arr.shape[-1] != b_arr.shape[-2]:
        raise ValueError(f"LoRA rank mismatch: {a_arr.shape} vs {b_arr.shape}")
    return np.einsum("...ir,...rj->...ij", a_arr, b_arr, optimize=True)


def discover_lora_modules(flat_params: Mapping[PathKey, Any]) -> list[LoRAModule]:
    modules: list[LoRAModule] = []
    for key in sorted(flat_params, key=format_key):
        if not key:
            continue
        leaf = key[-1]
        if leaf not in LORA_A_TO_BASE:
            continue
        b_leaf, base_leaf = LORA_A_TO_BASE[str(leaf)]
        parent = key[:-1]
        b_key = (*parent, b_leaf)
        base_key = (*parent, base_leaf)
        missing = [format_key(k) for k in (b_key, base_key) if k not in flat_params]
        if missing:
            raise KeyError(f"Missing LoRA companion leaves for {format_key(key)}: {missing}")
        modules.append(LoRAModule(base_key=base_key, a_key=key, b_key=b_key, kind=str(leaf)))
    if not modules:
        raise ValueError("No OpenPI LoRA modules found in the parameter tree.")
    return modules


def _shape(value: Any) -> tuple[int, ...]:
    return tuple(np.shape(value))


def validate_adapter_shapes(
    reference: Mapping[PathKey, Any],
    adapter: Mapping[PathKey, Any],
    modules: Sequence[LoRAModule],
    *,
    adapter_name: str,
) -> None:
    for module in modules:
        for key in (module.base_key, module.a_key, module.b_key):
            if key not in adapter:
                raise KeyError(f"Adapter {adapter_name} is missing {format_key(key)}")
            if _shape(reference[key]) != _shape(adapter[key]):
                raise ValueError(
                    f"Adapter {adapter_name} shape mismatch at {format_key(key)}: "
                    f"expected {_shape(reference[key])}, got {_shape(adapter[key])}"
                )


def cast_like(value: np.ndarray, reference: Any) -> Any:
    dtype = getattr(reference, "dtype", None)
    if dtype is None:
        return value
    if str(dtype) == "bfloat16":
        import jax.numpy as jnp

        return jnp.asarray(value, dtype=jnp.bfloat16)
    return value.astype(dtype, copy=False)


def zero_like(reference: Any) -> Any:
    dtype = getattr(reference, "dtype", None)
    if dtype is not None and str(dtype) == "bfloat16":
        import jax.numpy as jnp

        return jnp.zeros(np.shape(reference), dtype=jnp.bfloat16)
    return np.zeros_like(np.asarray(reference))


def build_stacked_params(
    base_params: Mapping[Any, Any],
    adapters: Sequence[tuple[AdapterSpec, Mapping[Any, Any]]],
    *,
    adapter_mode: AdapterMode,
    lora_scaling: float = 1.0,
    zero_lora_factors: bool = True,
) -> tuple[dict[Any, Any], dict[str, Any]]:
    if not adapters:
        raise ValueError("At least one adapter is required.")

    base_flat = flatten_tree(base_params)
    modules = discover_lora_modules(base_flat)
    result_flat: dict[PathKey, Any] = dict(base_flat)
    accumulators = {
        module.base_key: np.asarray(base_flat[module.base_key], dtype=np.float32).copy()
        for module in modules
    }

    previous_raw_updates: dict[PathKey, np.ndarray] | None = None
    adapter_reports: list[dict[str, Any]] = []

    for spec, params in adapters:
        flat = flatten_tree(params)
        validate_adapter_shapes(base_flat, flat, modules, adapter_name=spec.name)

        raw_updates: dict[PathKey, np.ndarray] = {}
        for module in modules:
            raw_updates[module.base_key] = lora_scaling * dense_lora_update(
                flat[module.a_key], flat[module.b_key]
            )

        if adapter_mode == "sequential-delta" and previous_raw_updates is not None:
            stage_updates = {
                key: update - previous_raw_updates[key]
                for key, update in raw_updates.items()
            }
        else:
            stage_updates = raw_updates

        for key, update in stage_updates.items():
            accumulators[key] += spec.alpha * update

        adapter_reports.append(
            {
                "name": spec.name,
                "params_path": str(spec.params_path),
                "alpha": spec.alpha,
                "mode_contribution": "raw_adapter" if previous_raw_updates is None else adapter_mode,
            }
        )
        previous_raw_updates = raw_updates

    for key, value in accumulators.items():
        result_flat[key] = cast_like(value, base_flat[key])

    if zero_lora_factors:
        for module in modules:
            result_flat[module.a_key] = zero_like(base_flat[module.a_key])
            result_flat[module.b_key] = zero_like(base_flat[module.b_key])

    report = {
        "adapter_mode": adapter_mode,
        "lora_scaling": lora_scaling,
        "zero_lora_factors": zero_lora_factors,
        "num_lora_modules": len(modules),
        "num_dense_weights_updated": len({module.base_key for module in modules}),
        "adapters": adapter_reports,
        "updated_weights": [
            {
                "base_key": format_key(module.base_key),
                "a_key": format_key(module.a_key),
                "b_key": format_key(module.b_key),
                "base_shape": list(_shape(base_flat[module.base_key])),
                "rank": int(_shape(base_flat[module.a_key])[-1]),
            }
            for module in modules
        ],
    }
    return unflatten_tree(result_flat), report


def parse_named_path(raw: str) -> tuple[str, Path]:
    if "=" not in raw:
        raise argparse.ArgumentTypeError("Expected NAME=/path/to/params")
    name, path = raw.split("=", 1)
    if not name:
        raise argparse.ArgumentTypeError("Adapter name cannot be empty.")
    return name, Path(path).expanduser()


def parse_alpha(raw: str) -> tuple[str, float]:
    if "=" not in raw:
        raise argparse.ArgumentTypeError("Expected NAME=WEIGHT")
    name, value = raw.split("=", 1)
    if not name:
        raise argparse.ArgumentTypeError("Alpha name cannot be empty.")
    try:
        alpha = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"Invalid alpha value {value!r}") from exc
    return name, alpha


def resolve_adapter_specs(adapter_args: Sequence[str], alpha_args: Sequence[str]) -> list[AdapterSpec]:
    adapters = [parse_named_path(raw) for raw in adapter_args]
    alphas = dict(parse_alpha(raw) for raw in alpha_args)
    names = [name for name, _ in adapters]
    missing = [name for name in names if name not in alphas]
    extra = [name for name in alphas if name not in names]
    if missing or extra:
        raise ValueError(f"Alpha names must match adapter names. missing={missing}, extra={extra}")
    return [AdapterSpec(name=name, params_path=path, alpha=alphas[name]) for name, path in adapters]


def validate_simplex(specs: Sequence[AdapterSpec], *, allow_non_simplex: bool, tolerance: float) -> None:
    total = sum(spec.alpha for spec in specs)
    negative = [spec.name for spec in specs if spec.alpha < 0.0]
    if negative:
        raise ValueError(f"Stacking alphas must be non-negative; got negative weights for {negative}")
    if not allow_non_simplex and abs(total - 1.0) > tolerance:
        raise ValueError(f"Stacking alphas must sum to 1.0, got {total:.8f}")


def restore_openpi_params(params_path: Path) -> Mapping[Any, Any]:
    if not params_path.exists() and not str(params_path).startswith("gs://"):
        raise FileNotFoundError(params_path)
    import openpi.models.model as openpi_model

    return openpi_model.restore_params(params_path, restore_type=np.ndarray)


def save_openpi_params(params: Mapping[Any, Any], params_dir: Path, *, overwrite: bool) -> None:
    if params_dir.exists():
        if not overwrite:
            raise FileExistsError(f"{params_dir} already exists; pass --overwrite to replace it.")
        shutil.rmtree(params_dir)
    params_dir.parent.mkdir(parents=True, exist_ok=True)

    import orbax.checkpoint as ocp

    with ocp.PyTreeCheckpointer() as checkpointer:
        checkpointer.save(params_dir, {"params": params})


def checkpoint_root_from_params(params_path: Path) -> Path:
    return params_path.parent if params_path.name == "params" else params_path


def infer_assets_dir(path: Path) -> Path:
    if path.name == "assets":
        return path
    if path.name == "params":
        return path.parent / "assets"
    return path / "assets"


def copy_assets(src: Path, output_checkpoint: Path, *, overwrite: bool) -> None:
    assets_dir = infer_assets_dir(src)
    if not assets_dir.exists():
        raise FileNotFoundError(f"Assets directory not found: {assets_dir}")
    dst = output_checkpoint / "assets"
    if dst.exists():
        if not overwrite:
            raise FileExistsError(f"{dst} already exists; pass --overwrite to replace it.")
        shutil.rmtree(dst)
    shutil.copytree(assets_dir, dst)


def write_manifest(output_checkpoint: Path, report: Mapping[str, Any], *, overwrite: bool) -> None:
    manifest_path = output_checkpoint / "lora_stacking_manifest.json"
    if manifest_path.exists() and not overwrite:
        raise FileExistsError(f"{manifest_path} already exists; pass --overwrite to replace it.")
    payload = {
        "created_at": dt.datetime.now(dt.UTC).isoformat(),
        **report,
    }
    manifest_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m recoverable_vla_lora_stacking.lora_stacking",
        description=__doc__,
    )
    parser.add_argument(
        "--adapter",
        action="append",
        required=True,
        help="Stage adapter params path as NAME=/path/to/checkpoint/params. Repeat once per stage.",
    )
    parser.add_argument(
        "--alpha",
        action="append",
        required=True,
        help="Stacking coefficient as NAME=WEIGHT. Names must match --adapter entries.",
    )
    parser.add_argument(
        "--base-params",
        type=Path,
        help="Optional common frozen backbone params. Defaults to the first adapter's params tree.",
    )
    parser.add_argument(
        "--adapter-mode",
        choices=["independent", "sequential-delta"],
        default="sequential-delta",
        help="How to interpret the listed adapter checkpoints.",
    )
    parser.add_argument(
        "--lora-scaling",
        type=float,
        default=1.0,
        help="OpenPI LoRA scaling value. The project configs use alpha=rank, so the default is 1.0.",
    )
    parser.add_argument(
        "--output-checkpoint",
        type=Path,
        required=True,
        help="Output checkpoint root. The script writes params/, assets/, and a manifest inside it.",
    )
    parser.add_argument(
        "--assets-from",
        type=Path,
        help="Checkpoint root, params dir, or assets dir to copy normalization assets from. Defaults to the last adapter.",
    )
    parser.add_argument("--overwrite", action="store_true", help="Replace an existing output checkpoint.")
    parser.add_argument("--dry-run", action="store_true", help="Load and stack params, but do not write files.")
    parser.add_argument("--no-copy-assets", action="store_true", help="Do not copy checkpoint assets.")
    parser.add_argument("--keep-lora-factors", action="store_true", help="Do not zero LoRA factors after dense merge.")
    parser.add_argument(
        "--allow-non-simplex",
        action="store_true",
        help="Allow alpha weights that do not sum to one. Useful for diagnostics, not for reported runs.",
    )
    parser.add_argument("--simplex-tolerance", type=float, default=1e-6)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_arg_parser().parse_args(argv)
    specs = resolve_adapter_specs(args.adapter, args.alpha)
    validate_simplex(specs, allow_non_simplex=args.allow_non_simplex, tolerance=args.simplex_tolerance)

    base_path = args.base_params or specs[0].params_path
    print(f"Loading base params: {base_path}")
    base_params = restore_openpi_params(base_path)

    loaded_adapters: list[tuple[AdapterSpec, Mapping[Any, Any]]] = []
    for spec in specs:
        print(f"Loading adapter {spec.name} alpha={spec.alpha}: {spec.params_path}")
        loaded_adapters.append((spec, restore_openpi_params(spec.params_path)))

    stacked_params, report = build_stacked_params(
        base_params,
        loaded_adapters,
        adapter_mode=args.adapter_mode,
        lora_scaling=args.lora_scaling,
        zero_lora_factors=not args.keep_lora_factors,
    )
    print(
        "Stacked "
        f"{report['num_lora_modules']} LoRA modules into "
        f"{report['num_dense_weights_updated']} dense weights."
    )

    if args.dry_run:
        print("Dry run requested; no files written.")
        return 0

    output_checkpoint = args.output_checkpoint.expanduser()
    save_openpi_params(stacked_params, output_checkpoint / "params", overwrite=args.overwrite)
    if not args.no_copy_assets:
        assets_source = args.assets_from or checkpoint_root_from_params(specs[-1].params_path)
        copy_assets(assets_source.expanduser(), output_checkpoint, overwrite=args.overwrite)
    write_manifest(output_checkpoint, report, overwrite=args.overwrite)
    print(f"Wrote stacked checkpoint: {output_checkpoint}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
