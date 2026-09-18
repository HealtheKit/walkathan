import 'package:supabase_flutter/supabase_flutter.dart';

// TODO: Replace these with your actual Supabase project credentials.
// You can find them in your Supabase Dashboard > Settings > API.
const String supabaseUrl = 'https://wyxfvskltoraontczdxf.supabase.co';
const String supabaseAnonKey = 'sb_publishable_Az0xqd7ZC0g3RRIzqYYABA_W6_DwXgo';

SupabaseClient get supabase => Supabase.instance.client;
