# Address lock inputs through root.inputs, never generated node labels.
def root_id($doc; $name):
  ($doc.nodes.root.inputs[$name]) as $id
  | if ($id | type) == "string" and $doc.nodes[$id] != null then $id
    else error("root input '" + $name + "' is absent or not direct") end;
def root_ids($doc; $names): [ $names[] | root_id($doc; .) ];
def refs($nodes; $id): [ ($nodes[$id].inputs? // {}) | .[]? | select(type == "string") ];
def closure($nodes; $roots):
  def walk($todo; $seen):
    if ($todo | length) == 0 then $seen
    else $todo[0] as $id
      | if $seen[$id] then walk($todo[1:]; $seen)
        else walk(($todo[1:] + refs($nodes; $id)); $seen + {($id): true}) end
    end;
  walk($roots; {});
def assert_candidates_unchanged($live; $new; $names):
  root_ids($live; $names) as $roots
  | if $roots != root_ids($new; $names) then error("candidate root mapping changed") else . end
  | closure($live.nodes; $roots) as $ids
  | if ([ $ids | keys[] | select($live.nodes[.] != $new.nodes[.]) ] | length) != 0
    then error("production update changed candidate closure") else . end;
def sandbox_promote($new; $names):
  . as $live
  | assert_candidates_unchanged($live; $new; ($names | map(. + "-candidate")))
  | root_ids($new; $names) as $roots
  | closure($new.nodes; $roots) as $ids
  | reduce ($ids | keys[]) as $id (. ; .nodes[$id] = $new.nodes[$id])
  | reduce $names[] as $name
      (. ; root_id($live; $name) as $to | root_id($new; $name) as $from | .nodes[$to] = $new.nodes[$from]);
def rewrite_node($node; $node_map; $follow_map):
  $node | if .inputs? == null then . else .inputs |= with_entries(
    if (.value | type) == "string" then .value = ($node_map[.value] // .value)
    elif (.value | type) == "array" then .value |= map(. as $x | ($follow_map[$x] // $x))
    else . end) end;
def candidate_promote($names):
  . as $live | ($names | map(. + "-candidate")) as $c_names
  | root_ids($live; $names) as $p_roots | root_ids($live; $c_names) as $c_roots
  | closure($live.nodes; $c_roots) as $ids
  | reduce range(0; $names | length) as $i ({}; .[$c_roots[$i]] = $p_roots[$i]) as $root_map
  | reduce ($ids | keys[]) as $id ($root_map; if has($id) then . else .[$id] = ("promoted-" + $id) end) as $node_map
  | reduce range(0; $names | length) as $i ({}; .[$c_names[$i]] = $names[$i]) as $follow_map
  | reduce $p_roots[] as $id ({}; .[$id] = $live.nodes[$id].original) as $originals
  | reduce ($ids | keys[]) as $source
      ($live; $node_map[$source] as $destination | .nodes[$destination] = rewrite_node($live.nodes[$source]; $node_map; $follow_map))
  | reduce $p_roots[] as $id (. ; .nodes[$id].original = $originals[$id]);
if $mode == "sandbox-promote" then $new[0] as $new | sandbox_promote($new; $inputs)
elif $mode == "candidate-promote" then candidate_promote($inputs)
else error("unknown mode") end
