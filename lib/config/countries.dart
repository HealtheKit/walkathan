/// Countries offered at onboarding (chosen by the user, never from GPS).
/// `null` code = "Other / prefer not to say". Extend as needed.
const List<({String? code, String name})> kCountries = [
  (code: 'KW', name: 'Kuwait'),
  (code: 'IN', name: 'India'),
  (code: 'AE', name: 'United Arab Emirates'),
  (code: 'SA', name: 'Saudi Arabia'),
  (code: 'QA', name: 'Qatar'),
  (code: 'BH', name: 'Bahrain'),
  (code: 'OM', name: 'Oman'),
  (code: 'LK', name: 'Sri Lanka'),
  (code: 'SG', name: 'Singapore'),
  (code: 'MY', name: 'Malaysia'),
  (code: 'GB', name: 'United Kingdom'),
  (code: 'US', name: 'United States'),
  (code: 'CA', name: 'Canada'),
  (code: 'AU', name: 'Australia'),
  (code: null, name: 'Other / prefer not to say'),
];
