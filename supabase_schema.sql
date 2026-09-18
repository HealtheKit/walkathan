-- Run this SQL in your Supabase Dashboard > SQL Editor to create the required tables.

-- Users profile table (linked to Supabase Auth)
CREATE TABLE IF NOT EXISTS public.users (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  name TEXT NOT NULL DEFAULT '',
  email TEXT NOT NULL DEFAULT '',
  gender TEXT NOT NULL DEFAULT 'male',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Enable Row Level Security
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

-- Users can read all profiles (needed for leaderboard)
CREATE POLICY "Users can view all profiles"
  ON public.users FOR SELECT
  TO authenticated
  USING (true);

-- Users can insert their own profile
CREATE POLICY "Users can insert own profile"
  ON public.users FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = id);

-- Users can update their own profile
CREATE POLICY "Users can update own profile"
  ON public.users FOR UPDATE
  TO authenticated
  USING (auth.uid() = id);

-- Daily steps table
CREATE TABLE IF NOT EXISTS public.daily_steps (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  date_key TEXT NOT NULL,
  steps INT NOT NULL DEFAULT 0,
  count INT NOT NULL DEFAULT 0,
  last_day TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(user_id, date_key)
);

-- Enable Row Level Security
ALTER TABLE public.daily_steps ENABLE ROW LEVEL SECURITY;

-- Users can read all daily_steps (needed for leaderboard)
CREATE POLICY "Users can view all daily_steps"
  ON public.daily_steps FOR SELECT
  TO authenticated
  USING (true);

-- Users can insert their own steps
CREATE POLICY "Users can insert own steps"
  ON public.daily_steps FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

-- Users can update their own steps
CREATE POLICY "Users can update own steps"
  ON public.daily_steps FOR UPDATE
  TO authenticated
  USING (auth.uid() = user_id);

-- Index for faster leaderboard queries
CREATE INDEX IF NOT EXISTS idx_daily_steps_user_date ON public.daily_steps(user_id, date_key);
CREATE INDEX IF NOT EXISTS idx_users_gender ON public.users(gender);

-- Trigger: auto-create a users row when a new auth user signs up.
-- This avoids RLS issues when email confirmation is enabled (no active session yet).
-- The signup code passes name/gender via signUp metadata.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.users (id, name, email, gender)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data ->> 'name', ''),
    COALESCE(NEW.email, ''),
    COALESCE(NEW.raw_user_meta_data ->> 'gender', 'male')
  );
  RETURN NEW;
END;
$$;

-- Drop existing trigger if any, then create
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
