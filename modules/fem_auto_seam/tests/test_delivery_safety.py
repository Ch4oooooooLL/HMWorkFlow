import unittest
from hmworkflow.fem_auto_seam.backend import build_recognition_plan
from hmworkflow.fem_auto_seam.recognition_v2 import _same_target_path_contains


class DeliverySafetyTests(unittest.TestCase):
    def candidate(self, **values):
        result = dict(candidate_id='MAIN', candidate_type='T_SEAM',
                      source_component_id=1, target_component_id=2,
                      target_component_ids=[2], source_node_ids=[91, 3, 42],
                      source_edge_pairs=[[91, 3], [3, 42]],
                      recognition_status='TRUSTED', auto_eligible=True,
                      projection_coverage=1.0, reason_codes=[], length=60.0)
        result.update(values)
        return result

    def test_complete_main_edge_is_delivered_without_reordering_ids(self):
        seeds = build_recognition_plan([self.candidate()])['trusted_seeds']
        self.assertEqual([91, 3, 42], seeds[0]['source_node_ids'])

    def test_only_unsafe_evidence_blocks_delivery(self):
        # Coverage, projection and skin findings are tolerance evidence: the
        # mesh executor validates the result, so they stay diagnostics instead
        # of suppressing a location the recognizer found.
        for reason in ('PARTIAL_COVERAGE', 'PROJECTION_JUMP', 'TARGET_NORMAL_JUMP',
                       'TARGET_GAP', 'HOLE_INTERRUPTION', 'SKIN_ERROR_BORDERLINE'):
            with self.subTest(reason=reason):
                plan = build_recognition_plan([self.candidate(reason_codes=[reason])], True, True)
                self.assertTrue(plan['trusted_seeds'])
        # Ambiguity and topology evidence would create the wrong weld, so they
        # still keep the candidate in review.
        for reason in ('TARGET_AMBIGUITY', 'MULTI_TARGET_UNCERTAIN',
                       'NON_MANIFOLD_REGION', 'NORMAL_INCONSISTENT',
                       'INNER_BOUNDARY_SOURCE', 'SHORT_WELD'):
            with self.subTest(reason=reason):
                plan = build_recognition_plan([self.candidate(reason_codes=[reason])], True, True)
                self.assertFalse(plan['trusted_seeds'])
                self.assertTrue(plan['potential_groups'])

    def test_duplicate_status_blocks_even_trusted_candidates(self):
        plan = build_recognition_plan([self.candidate(duplicate_status='POSSIBLE_DUPLICATE')])
        self.assertFalse(plan['trusted_seeds'])

    def test_short_fragment_cannot_hide_main_edge_sharing_two_of_three_nodes(self):
        main = self.candidate()
        fragment = self.candidate(source_node_ids=[91, 3], source_edge_pairs=[[91, 3]])
        self.assertFalse(_same_target_path_contains(fragment, main))
        self.assertTrue(_same_target_path_contains(main, fragment))

    def test_same_nodes_against_different_target_are_not_duplicates(self):
        main = self.candidate()
        other = self.candidate(target_component_ids=[4])
        self.assertFalse(_same_target_path_contains(main, other))

    def test_adjacent_edges_are_not_duplicate_paths(self):
        a = self.candidate(source_edge_pairs=[[91, 3]])
        b = self.candidate(source_edge_pairs=[[3, 42]])
        self.assertFalse(_same_target_path_contains(a, b))
