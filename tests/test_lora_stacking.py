from __future__ import annotations

import numpy as np

from recoverable_vla_lora_stacking import lora_stacking


def test_dense_lora_update_contracts_rank_axis() -> None:
    a = np.array([[1.0, 2.0], [3.0, 4.0]], dtype=np.float32)
    b = np.array([[5.0, 6.0, 7.0], [8.0, 9.0, 10.0]], dtype=np.float32)

    update = lora_stacking.dense_lora_update(a, b)

    np.testing.assert_allclose(update, a @ b)


def test_independent_stacking_materializes_dense_weight_and_zeros_factors() -> None:
    base = {
        "layer": {
            "w": np.ones((2, 2), dtype=np.float32),
            "lora_a": np.zeros((2, 1), dtype=np.float32),
            "lora_b": np.zeros((1, 2), dtype=np.float32),
        }
    }
    adapter_1 = {
        "layer": {
            "w": np.ones((2, 2), dtype=np.float32),
            "lora_a": np.array([[1.0], [0.0]], dtype=np.float32),
            "lora_b": np.array([[2.0, 3.0]], dtype=np.float32),
        }
    }
    adapter_2 = {
        "layer": {
            "w": np.ones((2, 2), dtype=np.float32),
            "lora_a": np.array([[0.0], [1.0]], dtype=np.float32),
            "lora_b": np.array([[4.0, 5.0]], dtype=np.float32),
        }
    }
    specs = [
        lora_stacking.AdapterSpec("a1", lora_stacking.Path("a1"), 0.25),
        lora_stacking.AdapterSpec("a2", lora_stacking.Path("a2"), 0.75),
    ]

    stacked, report = lora_stacking.build_stacked_params(
        base,
        [(specs[0], adapter_1), (specs[1], adapter_2)],
        adapter_mode="independent",
    )

    expected = np.array([[1.5, 1.75], [4.0, 4.75]], dtype=np.float32)
    np.testing.assert_allclose(stacked["layer"]["w"], expected)
    np.testing.assert_allclose(stacked["layer"]["lora_a"], np.zeros((2, 1), dtype=np.float32))
    np.testing.assert_allclose(stacked["layer"]["lora_b"], np.zeros((1, 2), dtype=np.float32))
    assert report["num_lora_modules"] == 1


def test_sequential_delta_uses_incremental_adapter_difference() -> None:
    base = {
        "ffn": {
            "linear": np.zeros((2, 2), dtype=np.float32),
            "linear_lora_a": np.zeros((2, 1), dtype=np.float32),
            "linear_lora_b": np.zeros((1, 2), dtype=np.float32),
        }
    }
    adapter_1 = {
        "ffn": {
            "linear": np.zeros((2, 2), dtype=np.float32),
            "linear_lora_a": np.array([[1.0], [0.0]], dtype=np.float32),
            "linear_lora_b": np.array([[2.0, 0.0]], dtype=np.float32),
        }
    }
    adapter_2 = {
        "ffn": {
            "linear": np.zeros((2, 2), dtype=np.float32),
            "linear_lora_a": np.array([[1.0], [1.0]], dtype=np.float32),
            "linear_lora_b": np.array([[2.0, 2.0]], dtype=np.float32),
        }
    }
    specs = [
        lora_stacking.AdapterSpec("stage2", lora_stacking.Path("stage2"), 0.5),
        lora_stacking.AdapterSpec("stage3", lora_stacking.Path("stage3"), 0.5),
    ]

    stacked, _ = lora_stacking.build_stacked_params(
        base,
        [(specs[0], adapter_1), (specs[1], adapter_2)],
        adapter_mode="sequential-delta",
    )

    raw_1 = np.array([[2.0, 0.0], [0.0, 0.0]], dtype=np.float32)
    raw_2 = np.array([[2.0, 2.0], [2.0, 2.0]], dtype=np.float32)
    expected = 0.5 * raw_1 + 0.5 * (raw_2 - raw_1)
    np.testing.assert_allclose(stacked["ffn"]["linear"], expected)
