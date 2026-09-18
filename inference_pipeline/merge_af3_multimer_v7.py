#!/usr/bin/env python3
"""
Merge two AlphaFold 3 precomputed MSA and template JSON files for multimer prediction.

This script combines individual chain data from separate AlphaFold 3 JSON files
while preserving MSA alignments and template information for each chain.

Supports:
- Single file merging
- Batch processing of all combinations from two directories
- Custom seed specification
- Single-pair mode for array job integration (--index-a, --index-b)
"""

import json
import string
import sys
import argparse
from pathlib import Path
from typing import Dict, List, Any, Optional, Tuple
from itertools import product


def load_json(filepath: Path) -> Dict[str, Any]:
    """Load JSON file and return parsed data."""
    with open(filepath, 'r') as f:
        return json.load(f)


def save_json(data: Dict[str, Any], filepath: Path, indent: int = 2) -> None:
    """Save data to JSON file with proper formatting."""
    with open(filepath, 'w') as f:
        json.dump(data, f, indent=indent)


def get_json_files(path: Path) -> List[Path]:
    """Get all JSON files from a path (file or directory), recursively searching subdirectories."""
    if path.is_file():
        if path.suffix.lower() == '.json':
            return [path]
        else:
            print(f"Warning: {path} is not a JSON file, skipping.", file=sys.stderr)
            return []
    elif path.is_dir():
        # Use rglob for recursive search
        json_files = sorted(path.rglob('*.json'))
        return json_files
    else:
        print(f"Error: {path} is neither a file nor a directory", file=sys.stderr)
        return []


def get_json_files_verbose(path: Path) -> List[Path]:
    """Get all JSON files with verbose output about what was found."""
    json_files = get_json_files(path)
    
    if path.is_dir() and json_files:
        # Print summary of found files
        depth_counts = {}
        for f in json_files:
            relative_path = f.relative_to(path)
            depth = len(relative_path.parts) - 1
            depth_counts[depth] = depth_counts.get(depth, 0) + 1
        
        print(f"  Found {len(json_files)} JSON files in {path}:")
        for depth in sorted(depth_counts.keys()):
            if depth == 0:
                print(f"    - {depth_counts[depth]} in root directory")
            else:
                print(f"    - {depth_counts[depth]} in {'sub' * depth}directories")
    elif path.is_dir() and not json_files:
        print(f"Warning: No JSON files found in {path} or its subdirectories")
    
    return json_files


def extract_protein_name(filepath: Path) -> str:
    """Extract clean protein name from filepath, removing common suffixes."""
    name = filepath.stem
    # Remove common suffixes
    for suffix in ['_data', '_msa', '_template', '_input']:
        name = name.replace(suffix, '')
    return name


# Entity keys AF3 accepts inside "sequences". v6 only handled 'protein', so a
# ligand or nucleic-acid entity kept whatever chain id it arrived with and
# could collide with an assigned one.
ENTITY_KEYS = ('protein', 'rna', 'dna', 'ligand')


def chain_id_sequence(n: int) -> List[str]:
    """
    Generate n chain IDs: A..Z, then AA..AZ, BA.. and so on.

    AF3 accepts multi-letter chain IDs, so this does not run out at 26 the way
    a bare ascii_uppercase index would.
    """
    ids = []
    i = 0
    while len(ids) < n:
        label, k = "", i
        while True:
            label = string.ascii_uppercase[k % 26] + label
            k = k // 26 - 1
            if k < 0:
                break
        ids.append(label)
        i += 1
    return ids


def json_list(data: Dict[str, Any], key: str) -> List[Any]:
    """
    Fetch a list-valued key, treating an explicit null as an empty list.

    dict.get(key, []) only returns the default when the key is ABSENT. AF3
    data-pipeline output frequently writes "userCCD": null and
    "bondedAtomPairs": null, in which case .get returns None and any iteration
    over it raises TypeError.
    """
    value = data.get(key)
    return value if isinstance(value, list) else []


def entity_key(sequence_data: Dict[str, Any]) -> Optional[str]:
    """Return which entity key ('protein', 'ligand', ...) this entry uses."""
    for key in ENTITY_KEYS:
        if key in sequence_data:
            return key
    return None


def update_chain_id(sequence_data: Dict[str, Any], new_chain_id, verbose: bool = True) -> Dict[str, Any]:
    """
    Set the chain ID(s) on a sequence entry.

    new_chain_id may be a single string or a list. A list is AF3's native way
    to express stoichiometry: one entity, several copies. That matters beyond
    tidiness — AF3 computes the MSA once per ENTITY, so a 6-copy list costs one
    MSA search while six duplicated entries would cost six.
    """
    updated = json.loads(json.dumps(sequence_data))

    key = entity_key(updated)
    if key is not None and 'id' in updated[key]:
        updated[key]['id'] = new_chain_id
        if verbose:
            print(f"  Updated {key} chain ID to: {new_chain_id}")

    return updated


def stoichiometry_suffix(name: str, count: int) -> str:
    """Name fragment for a chain: 'NbNRC2' at 1 copy, 'NbNRC2x6' at 6."""
    return name if count <= 1 else f"{name}x{count}"


def parse_extra_chain(spec: str) -> tuple:
    """
    Parse an --extra-chain argument of the form PATH or PATH:N.

    Returns (Path, count). Rsplit on ':' so absolute paths survive; on Windows
    style paths this would need care, but AF3 inputs here are POSIX.
    """
    if ':' in spec:
        head, tail = spec.rsplit(':', 1)
        if tail.isdigit():
            return Path(head), int(tail)
    return Path(spec), 1


def perform_merge(
    data1: Dict[str, Any],
    data2: Dict[str, Any],
    file1_path: Path,
    file2_path: Path,
    chain_ids: Optional[List[str]] = None,
    multimer_name: Optional[str] = None,
    custom_seeds: Optional[List[int]] = None,
    verbose: bool = True,
    protomers_a: int = 1,
    protomers_b: int = 1,
    extra_components: Optional[List[Dict[str, Any]]] = None
) -> Dict[str, Any]:
    """
    Merge two (or more) AlphaFold 3 data dictionaries in memory.

    protomers_a / protomers_b give the copy number for each input. Copies are
    expressed as an id LIST on a single entity, which is AF3's native
    stoichiometry syntax, so the MSA is searched once per entity regardless of
    copy number.

    extra_components is a list of {'data', 'name', 'count'} dicts appended
    after chain B — used for a constant partner present in every job of a
    screen (a helper NLR, a ligand, a scaffold).

    Returns the merged data dictionary without saving to disk.
    """
    extra_components = extra_components or []

    # Assemble the component list in a fixed order: A, B, then extras.
    components = [
        {'data': data1, 'path': file1_path, 'count': max(1, protomers_a)},
        {'data': data2, 'path': file2_path, 'count': max(1, protomers_b)},
    ]
    for comp in extra_components:
        components.append({
            'data': comp['data'],
            'path': Path(comp.get('name', 'extra')),
            'count': max(1, comp.get('count', 1)),
        })

    # Total chains = sum over every entity in every component, times its copy
    # number. A component file may itself hold several entities (e.g. a protein
    # plus its ligand), so this is not simply len(components).
    total_chains = sum(
        len(json_list(c['data'], 'sequences')) * c['count'] for c in components
    )

    if chain_ids is None or len(chain_ids) < total_chains:
        # Generate rather than warn-and-patch: A..Z then AA.. so large
        # assemblies (a hexamer plus partners) do not run out of IDs.
        chain_ids = chain_id_sequence(total_chains)

    merged_data = {
        'dialect': data1.get('dialect', 'alphafold3'),
        'version': max(data1.get('version', 1), data2.get('version', 1)),
        'sequences': []
    }

    if multimer_name:
        merged_data['name'] = multimer_name
    else:
        name1 = extract_protein_name(file1_path)
        name2 = extract_protein_name(file2_path)
        merged_data['name'] = f"{name1}_{name2}_multimer"

    if verbose:
        print(f"  Total chains: {total_chains}")

    chain_idx = 0
    for comp in components:
        count = comp['count']
        for seq in json_list(comp['data'], 'sequences'):
            assigned = chain_ids[chain_idx:chain_idx + count]
            chain_idx += count

            # A single copy keeps the plain string form, matching v6 output
            # exactly so existing screens are unaffected.
            updated_seq = update_chain_id(
                seq, assigned[0] if count == 1 else assigned, verbose=False
            )
            merged_data['sequences'].append(updated_seq)

            if verbose:
                key = entity_key(updated_seq) or '?'
                if key == 'protein':
                    detail = f"{len(updated_seq['protein'].get('sequence', ''))} residues"
                else:
                    detail = key
                print(f"    Chains {','.join(assigned)}: {detail} from {comp['path'].name}")

    # Handle model seeds
    if custom_seeds is not None:
        merged_data['modelSeeds'] = custom_seeds
        if verbose:
            print(f"    Using custom seeds: {custom_seeds}")
    else:
        all_seeds = sorted(set().union(*[
            set(json_list(c['data'], 'modelSeeds')) for c in components
        ]))
        if all_seeds:
            merged_data['modelSeeds'] = all_seeds

    # Bonded atom pairs: these reference chain IDs, which this function has
    # just reassigned, so carrying them over is only safe for single-copy
    # inputs. Warn rather than emit silently wrong restraints.
    all_bonds = []
    for c in components:
        bonds = json_list(c['data'], 'bondedAtomPairs')
        if bonds:
            if c['count'] > 1:
                print(
                    f"WARNING: {c['path'].name} has bondedAtomPairs and a copy "
                    f"number of {c['count']}. Bond chain IDs refer to the "
                    f"original single-copy layout and are NOT remapped; "
                    f"dropping them. Check the merged JSON before relying on it.",
                    file=sys.stderr
                )
                continue
            all_bonds.extend(bonds)
    if all_bonds:
        merged_data['bondedAtomPairs'] = all_bonds

    # Merge user CCD, de-duplicated by code
    ccd_dict = {}
    for c in components:
        for ccd in json_list(c['data'], 'userCCD'):
            if isinstance(ccd, dict) and 'code' in ccd:
                ccd_dict[ccd['code']] = ccd
    if ccd_dict:
        merged_data['userCCD'] = list(ccd_dict.values())

    return merged_data


def merge_single_pair(
    dir1: Path,
    dir2: Path,
    index_a: int,
    index_b: int,
    output_file: Path,
    chain_ids: Optional[List[str]] = None,
    multimer_name: Optional[str] = None,
    custom_seeds: Optional[List[int]] = None,
    job_number: Optional[int] = None,
    quiet: bool = False,
    protomers_a: int = 1,
    protomers_b: int = 1,
    extra_chains: Optional[List[tuple]] = None
) -> Dict[str, str]:
    """
    Merge a single pair of files based on indices.
    
    This is designed for array job integration where each task processes
    one specific combination.
    
    Args:
        dir1: Directory containing chain A JSON files
        dir2: Directory containing chain B JSON files
        index_a: Index of file to select from dir1 (0-based)
        index_b: Index of file to select from dir2 (0-based)
        output_file: Path to write the merged JSON
        chain_ids: Optional chain IDs to use
        multimer_name: Optional name override (if None, auto-generated)
        custom_seeds: Optional custom seeds
        job_number: Optional job number to include in name
        quiet: If True, minimize output
    
    Returns:
        Dictionary with metadata about what was merged:
        {
            'chain_A': protein name from chain A,
            'chain_B': protein name from chain B,
            'output_file': path to output file,
            'output_name': name used in the merged JSON
        }
    """
    # Get sorted file lists
    files1 = get_json_files(dir1)
    files2 = get_json_files(dir2)
    
    if not files1:
        print(f"Error: No JSON files found in {dir1}", file=sys.stderr)
        sys.exit(1)
    if not files2:
        print(f"Error: No JSON files found in {dir2}", file=sys.stderr)
        sys.exit(1)
    
    # Validate indices
    if index_a < 0 or index_a >= len(files1):
        print(f"Error: index_a={index_a} out of range [0, {len(files1)-1}]", file=sys.stderr)
        sys.exit(1)
    if index_b < 0 or index_b >= len(files2):
        print(f"Error: index_b={index_b} out of range [0, {len(files2)-1}]", file=sys.stderr)
        sys.exit(1)
    
    # Select the specific files
    file1 = files1[index_a]
    file2 = files2[index_b]
    
    # Extract protein names
    name_a = extract_protein_name(file1)
    name_b = extract_protein_name(file2)
    
    if not quiet:
        print(f"Single-pair mode:")
        print(f"  Chain A [{index_a}]: {file1.name} -> {name_a}")
        print(f"  Chain B [{index_b}]: {file2.name} -> {name_b}")
    
    # Load JSON files
    data1 = load_json(file1)
    data2 = load_json(file2)
    
    # Load any constant extra chains
    extra_chains = extra_chains or []
    extra_components = []
    for path, count in extra_chains:
        path = Path(path)
        if path.is_dir():
            candidates = get_json_files(path)
            if not candidates:
                print(f"Error: no JSON in extra chain dir {path}", file=sys.stderr)
                sys.exit(1)
            path = candidates[0]
        if not path.exists():
            print(f"Error: extra chain not found: {path}", file=sys.stderr)
            sys.exit(1)
        extra_components.append({
            'data': load_json(path),
            'name': extract_protein_name(path),
            'count': count,
        })

    # Generate multimer name if not provided. Stoichiometry goes INTO the name
    # so two runs at different copy numbers cannot overwrite each other in the
    # same output directory.
    if multimer_name is None:
        frag_a = stoichiometry_suffix(name_a, protomers_a)
        frag_b = stoichiometry_suffix(name_b, protomers_b)
        base = f"{frag_a}_{frag_b}"
        if extra_components:
            extras = "_".join(
                stoichiometry_suffix(c['name'], c['count']) for c in extra_components
            )
            base = f"{base}_with_{extras}"
        if job_number is not None:
            multimer_name = f"job_{job_number}_{base}"
        else:
            multimer_name = f"{base}_multimer"
    
    # Add seed suffix if a single seed is provided (expanded mode)
    if custom_seeds is not None and len(custom_seeds) == 1:
        multimer_name = f"{multimer_name}_seed{custom_seeds[0]}"
    
    # Perform the merge
    merged_data = perform_merge(
        data1, data2,
        file1, file2,
        chain_ids=chain_ids,
        multimer_name=multimer_name,
        custom_seeds=custom_seeds,
        verbose=not quiet,
        protomers_a=protomers_a,
        protomers_b=protomers_b,
        extra_components=extra_components
    )
    
    # Ensure output directory exists
    output_file.parent.mkdir(parents=True, exist_ok=True)
    
    # Save the merged JSON
    save_json(merged_data, output_file)
    
    if not quiet:
        print(f"  Output: {output_file}")
        print(f"  Name: {merged_data['name']}")
    
    return {
        'chain_A': name_a,
        'chain_B': name_b,
        'output_file': str(output_file),
        'output_name': merged_data['name']
    }


def list_combinations(
    dir1: Path,
    dir2: Path,
    batch_name: Optional[str] = None,
    output_naming: str = 'both',
    custom_seeds: Optional[List[int]] = None,
    expand_seeds: bool = False,
    protomers_a: int = 1,
    protomers_b: int = 1,
    extra_chains: Optional[List[tuple]] = None
) -> List[Dict[str, Any]]:
    """
    List all combinations that would be generated from two directories.
    
    Useful for generating manifests or dry-run previews.
    
    Args:
        dir1: Directory containing chain A JSON files
        dir2: Directory containing chain B JSON files
        batch_name: Optional batch name for manifest
        output_naming: One of 'names', 'numbers', 'both'
        custom_seeds: Optional list of seed numbers
        expand_seeds: If True and multiple seeds provided, create separate entries per seed
    
    Returns:
        List of dictionaries with combination metadata
    """
    files1 = get_json_files(dir1)
    files2 = get_json_files(dir2)
    
    if not files1 or not files2:
        return []
    
    # Determine seeds to iterate over
    if expand_seeds and custom_seeds and len(custom_seeds) > 1:
        seeds_to_expand = custom_seeds
    else:
        seeds_to_expand = [None]  # None means no seed suffix
    
    # Resolve extra chain names once; they are constant across the screen.
    extra_chains = extra_chains or []
    extra_names = []
    for path, count in extra_chains:
        path = Path(path)
        if path.is_dir():
            candidates = get_json_files(path)
            if not candidates:
                continue
            path = candidates[0]
        extra_names.append(stoichiometry_suffix(extract_protein_name(path), count))
    extras_frag = ("_with_" + "_".join(extra_names)) if extra_names else ""

    combinations = []
    job_number = 0

    for i, file1 in enumerate(files1):
        for j, file2 in enumerate(files2):
            name_a = extract_protein_name(file1)
            name_b = extract_protein_name(file2)
            frag_a = stoichiometry_suffix(name_a, protomers_a)
            frag_b = stoichiometry_suffix(name_b, protomers_b)
            
            for seed in seeds_to_expand:
                # Generate output name based on naming style
                if output_naming == 'names':
                    output_name = f"{frag_a}_{frag_b}{extras_frag}"
                elif output_naming == 'numbers':
                    output_name = f"job_{job_number}"
                else:  # 'both'
                    output_name = f"job_{job_number}_{frag_a}_{frag_b}{extras_frag}"
                
                # Add seed suffix if expanding
                if seed is not None:
                    output_name = f"{output_name}_seed{seed}"
                
                combo = {
                    'batch': batch_name or '',
                    'job_number': job_number,
                    'index_a': i,
                    'index_b': j,
                    'chain_A': name_a,
                    'chain_B': name_b,
                    'file_A': str(file1),
                    'file_B': str(file2),
                    'output_name': output_name,
                    'seed': seed  # Will be None if not expanding
                }
                combinations.append(combo)
                job_number += 1
    
    return combinations


def print_manifest(combinations: List[Dict[str, Any]], file=sys.stdout) -> None:
    """Print combinations as a TSV manifest."""
    if not combinations:
        print("No combinations to display.", file=file)
        return
    
    # Check if any combination has a seed value (i.e., seeds were expanded)
    has_seeds = any(combo.get('seed') is not None for combo in combinations)
    
    # Header
    if has_seeds:
        print("batch\tjob_number\tchain_A\tchain_B\tseed\toutput_name", file=file)
    else:
        print("batch\tjob_number\tchain_A\tchain_B\toutput_name", file=file)
    
    # Rows
    for combo in combinations:
        if has_seeds:
            seed_val = combo.get('seed', '')
            print(f"{combo['batch']}\t{combo['job_number']}\t{combo['chain_A']}\t{combo['chain_B']}\t{seed_val}\t{combo['output_name']}", file=file)
        else:
            print(f"{combo['batch']}\t{combo['job_number']}\t{combo['chain_A']}\t{combo['chain_B']}\t{combo['output_name']}", file=file)


def merge_af3_jsons(
    json1_path: Path,
    json2_path: Path,
    output_path: Path,
    chain_ids: Optional[List[str]] = None,
    multimer_name: Optional[str] = None,
    custom_seeds: Optional[List[int]] = None,
    verbose: bool = True
) -> None:
    """
    Merge two AlphaFold 3 JSON files for multimer prediction.
    
    Args:
        json1_path: Path to first JSON file
        json2_path: Path to second JSON file
        output_path: Path for output merged JSON file
        chain_ids: Optional list of chain IDs to use (default: ['A', 'B'])
        multimer_name: Optional name for the multimer (default: combines input names)
        custom_seeds: Optional list of custom seed numbers to use
        verbose: Whether to print detailed output
    """
    
    # Load both JSON files
    if verbose:
        print(f"Loading {json1_path.name}...")
    data1 = load_json(json1_path)
    
    if verbose:
        print(f"Loading {json2_path.name}...")
    data2 = load_json(json2_path)
    
    # Set default chain IDs if not provided
    if chain_ids is None:
        chain_ids = ['A', 'B']
    
    # Validate we have enough chain IDs
    total_chains = len(json_list(data1, 'sequences')) + len(json_list(data2, 'sequences'))
    if len(chain_ids) < total_chains:
        if verbose:
            print(f"Warning: Not enough chain IDs provided. Need {total_chains}, got {len(chain_ids)}")
        # Auto-generate additional chain IDs
        for i in range(len(chain_ids), total_chains):
            chain_ids.append(string.ascii_uppercase[i])
    
    # Create merged data structure
    merged_data = {
        'dialect': data1.get('dialect', 'alphafold3'),
        'version': max(data1.get('version', 1), data2.get('version', 1)),
        'sequences': []
    }
    
    # Set multimer name
    if multimer_name:
        merged_data['name'] = multimer_name
    else:
        # Combine names from input files
        name1 = data1.get('name', json1_path.stem)
        name2 = data2.get('name', json2_path.stem)
        merged_data['name'] = f"{name1}_{name2}_multimer"
    
    if verbose:
        print(f"\nMerging sequences with chain IDs: {chain_ids[:total_chains]}")
    
    # Process sequences from first file
    chain_idx = 0
    for seq in json_list(data1, 'sequences'):
        updated_seq = update_chain_id(seq, chain_ids[chain_idx], verbose)
        merged_data['sequences'].append(updated_seq)
        
        # Print sequence info
        if verbose and 'protein' in updated_seq:
            seq_len = len(updated_seq['protein'].get('sequence', ''))
            print(f"  Added chain {chain_ids[chain_idx]}: {seq_len} residues from {json1_path.name}")
        
        chain_idx += 1
    
    # Process sequences from second file
    for seq in json_list(data2, 'sequences'):
        updated_seq = update_chain_id(seq, chain_ids[chain_idx], verbose)
        merged_data['sequences'].append(updated_seq)
        
        # Print sequence info
        if verbose and 'protein' in updated_seq:
            seq_len = len(updated_seq['protein'].get('sequence', ''))
            print(f"  Added chain {chain_ids[chain_idx]}: {seq_len} residues from {json2_path.name}")
        
        chain_idx += 1
    
    # Handle model seeds
    if custom_seeds is not None:
        # Use custom seeds if provided
        merged_data['modelSeeds'] = custom_seeds
        if verbose:
            print(f"\nUsing custom model seeds: {custom_seeds}")
    else:
        # Merge modelSeeds from input files (use union of both)
        seeds1 = set(json_list(data1, 'modelSeeds'))
        seeds2 = set(json_list(data2, 'modelSeeds'))
        all_seeds = sorted(seeds1.union(seeds2))
        if all_seeds:
            merged_data['modelSeeds'] = all_seeds
            if verbose:
                print(f"\nModel seeds from input files: {all_seeds}")
    
    # Handle bonded atom pairs if present in either file
    bonds1 = json_list(data1, 'bondedAtomPairs')
    bonds2 = json_list(data2, 'bondedAtomPairs')
    
    if bonds1 or bonds2:
        merged_data['bondedAtomPairs'] = bonds1 + bonds2
        if verbose and (bonds1 or bonds2):
            print(f"\nWarning: Bonded atom pairs detected. Manual verification recommended.")
    
    # Merge user CCD if present
    ccd1 = json_list(data1, 'userCCD')
    ccd2 = json_list(data2, 'userCCD')
    if ccd1 or ccd2:
        ccd_dict = {}
        for ccd in ccd1 + ccd2:
            if isinstance(ccd, dict) and 'code' in ccd:
                ccd_dict[ccd['code']] = ccd
        merged_data['userCCD'] = list(ccd_dict.values())
    
    # Save merged JSON
    if verbose:
        print(f"\nSaving merged JSON to: {output_path}")
    
    output_path.parent.mkdir(parents=True, exist_ok=True)
    save_json(merged_data, output_path)
    
    # Print summary
    if verbose:
        print("\n=== Merge Summary ===")
        print(f"Output name: {merged_data['name']}")
        print(f"Total chains: {len(merged_data['sequences'])}")
        
        for i, seq in enumerate(merged_data['sequences']):
            if 'protein' in seq:
                protein = seq['protein']
                chain_id = protein.get('id', 'Unknown')
                seq_len = len(protein.get('sequence', ''))
                has_unpaired_msa = 'unpairedMsa' in protein and protein['unpairedMsa']
                has_paired_msa = 'pairedMsa' in protein and protein['pairedMsa']
                has_templates = 'templates' in protein and protein['templates']
                
                print(f"  Chain {chain_id}: {seq_len} residues")
                if has_unpaired_msa:
                    print(f"    - Has unpaired MSA")
                if has_paired_msa:
                    print(f"    - Has paired MSA")
                if has_templates:
                    n_templates = len(protein['templates']) if isinstance(protein['templates'], list) else 1
                    print(f"    - Has {n_templates} template(s)")
        
        print(f"\nMerge completed successfully!")


def generate_output_name(file1: Path, file2: Path, output_dir: Path, all_files1: List[Path] = None, all_files2: List[Path] = None) -> Path:
    """Generate output filename for a file pair, handling potential name conflicts."""
    name1 = extract_protein_name(file1)
    name2 = extract_protein_name(file2)
    
    # Check if we need to add path context to avoid conflicts
    need_context1 = False
    need_context2 = False
    
    if all_files1:
        same_stem1 = [f for f in all_files1 if f.stem == file1.stem]
        if len(same_stem1) > 1:
            need_context1 = True
    
    if all_files2:
        same_stem2 = [f for f in all_files2 if f.stem == file2.stem]
        if len(same_stem2) > 1:
            need_context2 = True
    
    if need_context1 and file1.parent.name:
        name1 = f"{file1.parent.name}_{name1}"
    
    if need_context2 and file2.parent.name:
        name2 = f"{file2.parent.name}_{name2}"
    
    # Clean up the names
    name1 = name1.replace(' ', '_').replace('/', '_')
    name2 = name2.replace(' ', '_').replace('/', '_')
    
    return output_dir / f"{name1}_{name2}_multimer.json"


def convert_to_simple_format(merged_data: Dict[str, Any]) -> Dict[str, Any]:
    """
    Convert merged data to simplified AF3 batch format.
    This format removes MSAs/templates and uses proteinChain structure.
    """
    simplified = {
        'name': merged_data.get('name', 'unnamed'),
        'modelSeeds': json_list(merged_data, 'modelSeeds'),
        'sequences': []
    }
    
    for seq in json_list(merged_data, 'sequences'):
        if 'protein' in seq:
            protein = seq['protein']
            simplified_seq = {
                'proteinChain': {
                    'sequence': protein.get('sequence', ''),
                    'count': 1
                }
            }
            simplified['sequences'].append(simplified_seq)
        elif 'rna' in seq:
            simplified['sequences'].append({
                'rnaSequence': {
                    'sequence': seq['rna'].get('sequence', '')
                }
            })
        elif 'dna' in seq:
            simplified['sequences'].append({
                'dnaSequence': {
                    'sequence': seq['dna'].get('sequence', '')
                }
            })
        elif 'ligand' in seq:
            simplified['sequences'].append(seq)
    
    return simplified


def create_wrapped_output(
    all_configs: List[Tuple[Path, Path, Dict[str, Any]]],
    output_path: Path,
    wrap_format: str = "array",
    simple_format: bool = False,
    expand_seeds: bool = False
) -> None:
    """
    Create a single JSON file containing all merged configurations.
    """
    processed_configs = []
    
    for file1, file2, data in all_configs:
        if expand_seeds and 'modelSeeds' in data and len(data['modelSeeds']) > 1:
            base_name = data.get('name', 'unnamed')
            for seed in data['modelSeeds']:
                seed_data = json.loads(json.dumps(data))
                seed_data['modelSeeds'] = [seed]
                seed_data['name'] = f"{base_name}_seed{seed}"
                
                if simple_format:
                    processed_configs.append(convert_to_simple_format(seed_data))
                else:
                    seed_data.pop('dialect', None)
                    seed_data.pop('version', None)
                    processed_configs.append(seed_data)
        else:
            if simple_format:
                processed_configs.append(convert_to_simple_format(data))
            else:
                config_data = json.loads(json.dumps(data))
                config_data.pop('dialect', None)
                config_data.pop('version', None)
                processed_configs.append(config_data)
    
    if wrap_format == "array":
        wrapped_data = processed_configs
    else:
        wrapped_data = {
            "metadata": {
                "total_jobs": len(processed_configs),
                "creation_time": str(Path.cwd()),
                "wrap_format": "indexed",
                "simple_format": simple_format,
                "expanded_seeds": expand_seeds
            },
            "jobs": {}
        }
        
        for i, config in enumerate(processed_configs):
            job_name = config.get('name', f'job_{i:03d}')
            wrapped_data["jobs"][job_name] = {
                "index": i,
                "config": config
            }
    
    print(f"\nSaving wrapped output to: {output_path}")
    save_json(wrapped_data, output_path)
    
    original_count = len(all_configs)
    final_count = len(processed_configs)
    
    print(f"  Original combinations: {original_count}")
    if expand_seeds and final_count > original_count:
        print(f"  Expanded to {final_count} configurations (seeds as separate jobs)")
    else:
        print(f"  Total configurations: {final_count}")
    
    if simple_format:
        print(f"  Format: Simplified (no MSAs/templates)")
    else:
        print(f"  Format: Full (includes MSAs and templates)")
    print(f"  ✓ AF3-compatible (no dialect/version fields)")


def process_file_pairs(
    path1: Path,
    path2: Path, 
    output: Path,
    chain_ids: Optional[List[str]] = None,
    multimer_name: Optional[str] = None,
    custom_seeds: Optional[List[int]] = None,
    wrap_output: bool = False,
    wrap_format: str = "array",
    simple_format: bool = False,
    expand_seeds: bool = False
) -> None:
    """
    Process single files or all combinations from directories.
    """
    files1 = get_json_files_verbose(path1)
    files2 = get_json_files_verbose(path2)
    
    if not files1 or not files2:
        print("Error: No valid JSON files found to process", file=sys.stderr)
        sys.exit(1)
    
    is_batch = len(files1) > 1 or len(files2) > 1
    all_configurations = []
    
    if is_batch or wrap_output:
        if wrap_output:
            if output.suffix != '.json':
                output = output / 'wrapped_multimers.json'
            output.parent.mkdir(parents=True, exist_ok=True)
            
            print(f"Wrapped output mode:")
            print(f"  Found {len(files1)} files in {path1}")
            print(f"  Found {len(files2)} files in {path2}")
            print(f"  Will generate {len(files1) * len(files2)} combinations")
            print(f"  Output file: {output}")
            print("=" * 60)
        else:
            if output.suffix == '.json':
                output = output.parent
            output.mkdir(parents=True, exist_ok=True)
            
            print(f"Batch processing mode:")
            print(f"  Found {len(files1)} files in {path1}")
            print(f"  Found {len(files2)} files in {path2}")
            print(f"  Will generate {len(files1) * len(files2)} combinations")
            print(f"  Output directory: {output}")
            print("=" * 60)
        
        total_combinations = len(files1) * len(files2)
        combination_count = 0
        
        for file1, file2 in product(files1, files2):
            combination_count += 1
            
            if wrap_output:
                print(f"\n[{combination_count}/{total_combinations}] Processing combination:")
                print(f"  {file1.name} + {file2.name}")
                print("-" * 40)
                
                try:
                    data1 = load_json(file1)
                    data2 = load_json(file2)
                    
                    merged_data = perform_merge(
                        data1, data2, 
                        file1, file2,
                        chain_ids=chain_ids,
                        multimer_name=multimer_name,
                        custom_seeds=custom_seeds,
                        verbose=True
                    )
                    
                    all_configurations.append((file1, file2, merged_data))
                    
                except Exception as e:
                    print(f"Error processing {file1.name} + {file2.name}: {e}", file=sys.stderr)
                    continue
            else:
                base_output_file = generate_output_name(file1, file2, output, files1, files2)
                
                if expand_seeds and custom_seeds and len(custom_seeds) > 1:
                    seeds_to_expand = custom_seeds
                else:
                    seeds_to_expand = [None]
                
                for seed in seeds_to_expand:
                    if seed is not None:
                        output_file = base_output_file.parent / f"{base_output_file.stem.replace('.json', '')}_seed{seed}.json"
                        current_seeds = [seed]
                        seed_suffix = f" (seed {seed})"
                    else:
                        output_file = base_output_file
                        current_seeds = custom_seeds
                        seed_suffix = ""
                    
                    print(f"\n[{combination_count}/{total_combinations}] Processing combination{seed_suffix}:")
                    print(f"  {file1.name} + {file2.name} -> {output_file.name}")
                    print("-" * 40)
                    
                    current_multimer_name = multimer_name
                    if seed is not None:
                        if multimer_name:
                            current_multimer_name = f"{multimer_name}_seed{seed}"
                        else:
                            name1 = extract_protein_name(file1)
                            name2 = extract_protein_name(file2)
                            current_multimer_name = f"{name1}_{name2}_multimer_seed{seed}"
                    
                    try:
                        merge_af3_jsons(
                            file1,
                            file2,
                            output_file,
                            chain_ids=chain_ids,
                            multimer_name=current_multimer_name,
                            custom_seeds=current_seeds,
                            verbose=True
                        )
                    except Exception as e:
                        print(f"Error processing {file1.name} + {file2.name}: {e}", file=sys.stderr)
                        continue
        
        if wrap_output:
            create_wrapped_output(all_configurations, output, wrap_format, simple_format, expand_seeds)
            print("\n" + "=" * 60)
            print(f"Wrapped output complete! All {len(all_configurations)} combinations saved to {output}")
            print("✓ Ready for direct use with AlphaFold 3 batch processing")
        else:
            print("\n" + "=" * 60)
            print(f"Batch processing complete! Generated {combination_count} merged files in {output}")
        
    else:
        if output.suffix != '.json':
            output.mkdir(parents=True, exist_ok=True)
            base_output = generate_output_name(files1[0], files2[0], output, files1, files2)
        else:
            output.parent.mkdir(parents=True, exist_ok=True)
            base_output = output
        
        if expand_seeds and custom_seeds and len(custom_seeds) > 1:
            seeds_to_expand = custom_seeds
        else:
            seeds_to_expand = [None]
        
        for seed in seeds_to_expand:
            if seed is not None:
                output_file = base_output.parent / f"{base_output.stem}_seed{seed}.json"
                current_seeds = [seed]
                if multimer_name:
                    current_multimer_name = f"{multimer_name}_seed{seed}"
                else:
                    name1 = extract_protein_name(files1[0])
                    name2 = extract_protein_name(files2[0])
                    current_multimer_name = f"{name1}_{name2}_multimer_seed{seed}"
            else:
                output_file = base_output
                current_seeds = custom_seeds
                current_multimer_name = multimer_name
            
            merge_af3_jsons(
                files1[0],
                files2[0],
                output_file,
                chain_ids=chain_ids,
                multimer_name=current_multimer_name,
                custom_seeds=current_seeds,
                verbose=True
            )


def main():
    """Main function to handle command line arguments."""
    parser = argparse.ArgumentParser(
        description="Merge AlphaFold 3 precomputed MSA/template JSON files for multimer prediction",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Basic merge of two files with default chain IDs (A, B)
  python merge_af3_multimer.py input1.json input2.json output.json
  
  # Specify custom chain IDs
  python merge_af3_multimer.py input1.json input2.json output.json --chain-ids A B
  
  # Set custom multimer name
  python merge_af3_multimer.py input1.json input2.json output.json --name "MyComplex"
  
  # Use custom seed numbers
  python merge_af3_multimer.py input1.json input2.json output.json --seeds 42 123 456
  
  # Batch processing: merge all combinations from two directories
  python merge_af3_multimer.py dir1/ dir2/ output_dir/
  
  # Batch processing with custom seeds
  python merge_af3_multimer.py dir1/ dir2/ output_dir/ --seeds 42 123
  
  # Wrap all combinations in a single JSON file (AF3 batch compatible, keeps MSAs)
  python merge_af3_multimer.py dir1/ dir2/ wrapped.json --wrap-output
  
  # Use simplified format without MSAs (like AlphaFold Server)
  python merge_af3_multimer.py dir1/ dir2/ wrapped.json --wrap-output --simple-format
  
  # Wrap with indexed format for easier access
  python merge_af3_multimer.py dir1/ dir2/ wrapped.json --wrap-output --wrap-format indexed

  === Array Job Integration ===
  
  # Single-pair mode: merge specific files by index (for SLURM array jobs)
  python merge_af3_multimer.py dir1/ dir2/ --index-a 0 --index-b 3 --output-file /tmp/job_0.json
  
  # With job number in name
  python merge_af3_multimer.py dir1/ dir2/ --index-a 0 --index-b 3 --output-file /tmp/job_0.json --job-number 0
  
  # List all combinations (for generating manifests)
  python merge_af3_multimer.py dir1/ dir2/ --list-combinations --batch my_screen
  
  # List with specific output naming style
  python merge_af3_multimer.py dir1/ dir2/ --list-combinations --output-naming both
        """
    )
    
    parser.add_argument(
        'json1',
        type=Path,
        help='Path to first AlphaFold 3 JSON file or directory containing JSON files'
    )
    parser.add_argument(
        'json2',
        type=Path,
        help='Path to second AlphaFold 3 JSON file or directory containing JSON files'
    )
    parser.add_argument(
        'output',
        type=Path,
        nargs='?',
        default=None,
        help='Path for output merged JSON file or directory for batch output (not required for --list-combinations)'
    )
    stoich_group = parser.add_argument_group(
        'Stoichiometry and extra chains',
        'Copy numbers per input, and constant partners added to every job')
    stoich_group.add_argument(
        '--protomers-a',
        type=int,
        default=1,
        help='Copies of each chain A entity (default: 1). Uses AF3 native id '
             'lists, so the MSA is searched once regardless of copy number.'
    )
    stoich_group.add_argument(
        '--protomers-b',
        type=int,
        default=1,
        help='Copies of each chain B entity (default: 1)'
    )
    stoich_group.add_argument(
        '--extra-chain',
        action='append',
        default=None,
        metavar='PATH[:N]',
        help='A constant chain added to EVERY combination, optionally with a '
             'copy count, e.g. --extra-chain helpers/NRC4/NRC4_data.json:2. '
             'Repeatable. Does not multiply the job count.'
    )

    parser.add_argument(
        '--chain-ids',
        nargs='+',
        default=None,
        help='Chain IDs to use (default: A B)'
    )
    parser.add_argument(
        '--name',
        type=str,
        default=None,
        help='Name for the multimer complex (not used in batch mode)'
    )
    parser.add_argument(
        '--seeds',
        nargs='+',
        type=int,
        default=None,
        help='Custom seed numbers to use instead of seeds from input files'
    )
    parser.add_argument(
        '--wrap-output',
        action='store_true',
        help='Wrap all combinations in a single JSON file instead of creating separate files'
    )
    parser.add_argument(
        '--wrap-format',
        choices=['array', 'indexed'],
        default='array',
        help='Format for wrapped output: "array" (simple list) or "indexed" (dictionary with metadata)'
    )
    parser.add_argument(
        '--simple-format',
        action='store_true',
        help='Convert to simplified format (remove MSAs/templates, use proteinChain structure)'
    )
    parser.add_argument(
        '--expand-seeds',
        action='store_true',
        help='Create separate configurations for each seed value (like AF3 Server format)'
    )
    
    # === New arguments for array job integration ===
    array_group = parser.add_argument_group('Array Job Integration', 
        'Options for single-pair mode used by SLURM array jobs')
    
    array_group.add_argument(
        '--index-a',
        type=int,
        default=None,
        help='Index of file to select from first directory (0-based)'
    )
    array_group.add_argument(
        '--index-b',
        type=int,
        default=None,
        help='Index of file to select from second directory (0-based)'
    )
    array_group.add_argument(
        '--output-file',
        type=Path,
        default=None,
        help='Exact output file path for single-pair mode'
    )
    array_group.add_argument(
        '--job-number',
        type=int,
        default=None,
        help='Job number to include in the multimer name (e.g., job_0_NRC2a_AVR2)'
    )
    array_group.add_argument(
        '--quiet', '-q',
        action='store_true',
        help='Minimize output (useful for array jobs)'
    )
    
    # === Manifest/listing options ===
    manifest_group = parser.add_argument_group('Manifest Generation',
        'Options for listing combinations and generating manifests')
    
    manifest_group.add_argument(
        '--list-combinations',
        action='store_true',
        help='List all combinations as TSV without processing (for manifest generation)'
    )
    manifest_group.add_argument(
        '--batch',
        type=str,
        default=None,
        help='Batch name for manifest output'
    )
    manifest_group.add_argument(
        '--output-naming',
        choices=['names', 'numbers', 'both'],
        default='both',
        help='Naming style for outputs: names (NRC2a_AVR2), numbers (job_0), both (job_0_NRC2a_AVR2)'
    )
    
    args = parser.parse_args()

    if args.protomers_a < 1 or args.protomers_b < 1:
        print("Error: --protomers-a/--protomers-b must be >= 1", file=sys.stderr)
        sys.exit(1)

    extra_chains = [parse_extra_chain(spec) for spec in (args.extra_chain or [])]
    for path, _count in extra_chains:
        if not Path(path).exists():
            print(f"Error: --extra-chain path not found: {path}", file=sys.stderr)
            sys.exit(1)

    # Validate input paths exist
    if not args.json1.exists():
        print(f"Error: Input path not found: {args.json1}", file=sys.stderr)
        sys.exit(1)
    if not args.json2.exists():
        print(f"Error: Input path not found: {args.json2}", file=sys.stderr)
        sys.exit(1)
    
    # === Mode: List combinations ===
    if args.list_combinations:
        combinations = list_combinations(
            args.json1,
            args.json2,
            batch_name=args.batch,
            output_naming=args.output_naming,
            custom_seeds=args.seeds,
            expand_seeds=args.expand_seeds,
            protomers_a=args.protomers_a,
            protomers_b=args.protomers_b,
            extra_chains=extra_chains
        )
        print_manifest(combinations)
        return
    
    # === Mode: Single-pair (array job) ===
    if args.index_a is not None and args.index_b is not None:
        if args.output_file is None:
            print("Error: --output-file is required when using --index-a and --index-b", file=sys.stderr)
            sys.exit(1)
        
        result = merge_single_pair(
            args.json1,
            args.json2,
            args.index_a,
            args.index_b,
            args.output_file,
            chain_ids=args.chain_ids,
            multimer_name=args.name,
            custom_seeds=args.seeds,
            job_number=args.job_number,
            quiet=args.quiet,
            protomers_a=args.protomers_a,
            protomers_b=args.protomers_b,
            extra_chains=extra_chains
        )
        
        # Print result as JSON for easy parsing by bash scripts
        if args.quiet:
            print(json.dumps(result))
        
        return
    
    # === Mode: Standard batch/single processing ===
    if args.output is None:
        print("Error: output path is required for batch processing", file=sys.stderr)
        sys.exit(1)
    
    process_file_pairs(
        args.json1,
        args.json2,
        args.output,
        chain_ids=args.chain_ids,
        multimer_name=args.name,
        custom_seeds=args.seeds,
        wrap_output=args.wrap_output,
        wrap_format=args.wrap_format,
        simple_format=args.simple_format,
        expand_seeds=args.expand_seeds
    )


if __name__ == "__main__":
    main()
