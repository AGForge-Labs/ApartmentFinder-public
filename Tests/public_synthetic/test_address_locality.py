"""Exercise the actual Swift locality regex; Foundation execution is separate."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AddressLocalityPatternTests(unittest.TestCase):
    def setUp(self):
        source = (ROOT / 'Sources/ApartmentCore/LocalSearch.swift').read_text(encoding='utf-8')
        shared = re.search(r'static let localitySuffixPattern = #"([^"\n]+)"#', source)
        original = re.search(r'of: #"([^"\n]+)"#, with: ""', source)
        self.pattern = (shared or original).group(1)

    def strip(self, address):
        return re.sub(self.pattern, '', address).strip(' ,.\t\r\n')

    def test_henderson_suffix_formats_preserve_leading_zero_and_repeated_units(self):
        for suffix in ('.Henderson.NV.89052', ', Henderson, NV 89014',
                       ' Henderson Nevada 89044-1234', '\nHenderson NV 89052',
                       ',Henderson 89044', ',Henderson'):
            with self.subTest(suffix=suffix):
                self.assertEqual(self.strip('100 Fictional Rd 04102' + suffix), '100 Fictional Rd 04102')
                self.assertEqual(self.strip('100 Fictional Rd 04102\n04102' + suffix),
                                 '100 Fictional Rd 04102\n04102')

    def test_locality_words_inside_street_names_are_retained(self):
        for street in ('100 Las Vegas Blvd', '100 Henderson Dr', '100 Nevada Ave', '100 Henderson'):
            with self.subTest(street=street):
                self.assertEqual(self.strip(street), street)
                self.assertEqual(self.strip(street + ', Henderson NV 89052'), street)
                self.assertEqual(self.strip(street + '.Las Vegas.NV.89123'), street)

    def test_other_city_suffixes_are_not_silently_accepted(self):
        address = '100 Fictional Rd 001.Other City.Other State.99999'
        self.assertEqual(self.strip(address), address)


if __name__ == '__main__':
    unittest.main()
