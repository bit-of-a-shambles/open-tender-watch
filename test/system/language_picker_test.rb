require "application_system_test_case"

class LanguagePickerTest < ApplicationSystemTestCase
  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  def en_link = find("a[href*='/locale/en']")
  def pt_link = find("a[href*='/locale/pt']")

  def html_lang
    page.evaluate_script("document.documentElement.lang")
  end

  # ------------------------------------------------------------------
  # Default state
  # ------------------------------------------------------------------

  test "default locale is English" do
    visit root_url
    assert_equal "en", html_lang
  end

  test "EN button is active by default" do
    visit root_url
    assert_includes en_link[:class], "border-[#c8a84e55]",
      "EN link should have the active gold border class by default"
    assert_not_includes en_link[:class], "opacity-50",
      "EN link should not be dimmed by default"
  end

  test "PT button is inactive by default" do
    visit root_url
    assert_includes pt_link[:class], "opacity-50",
      "PT link should be dimmed when English is active"
    assert_not_includes pt_link[:class], "border-[#c8a84e55]",
      "PT link should not have the active gold border when English is active"
  end

  # ------------------------------------------------------------------
  # Switching to Portuguese
  # ------------------------------------------------------------------

  test "clicking PT switches locale to Portuguese" do
    visit root_url
    pt_link.click
    assert_equal "pt", html_lang
  end

  test "nav shows Portuguese labels after switching to PT" do
    visit root_url
    pt_link.click
    assert_text "Cruzamento automatizado"
    assert_no_text "Automated cross-referencing"
  end

  test "PT button becomes active after switching" do
    visit root_url
    pt_link.click
    assert_includes pt_link[:class], "border-[#c8a84e55]",
      "PT link should have the active gold border after switching"
    assert_not_includes pt_link[:class], "opacity-50",
      "PT link should not be dimmed when active"
  end

  test "EN button becomes inactive after switching to PT" do
    visit root_url
    pt_link.click
    assert_includes en_link[:class], "opacity-50",
      "EN link should be dimmed when Portuguese is active"
    assert_not_includes en_link[:class], "border-[#c8a84e55]",
      "EN link should not have the active gold border when PT is active"
  end

  # ------------------------------------------------------------------
  # Switching back to English
  # ------------------------------------------------------------------

  test "clicking EN after PT restores English locale" do
    visit root_url
    pt_link.click
    assert_equal "pt", html_lang

    en_link.click
    assert_equal "en", html_lang
  end

  test "nav shows English labels after switching back to EN" do
    visit root_url
    pt_link.click
    en_link.click
    assert_text "Automated cross-referencing"
    assert_no_text "Cruzamento automatizado"
  end

  # ------------------------------------------------------------------
  # Locale persistence across navigation
  # ------------------------------------------------------------------

  test "Portuguese locale persists when navigating to contracts page" do
    visit root_url
    pt_link.click
    assert_equal "pt", html_lang

    visit contracts_url
    assert_equal "pt", html_lang,
      "Locale should persist via session cookie across navigation"
    assert_text "Contratos"
  end

  test "Portuguese locale persists when navigating back to root" do
    visit root_url
    pt_link.click

    visit root_url
    assert_equal "pt", html_lang
    assert_text "Cruzamento automatizado"
  end

  # ------------------------------------------------------------------
  # Picker visibility across pages
  # ------------------------------------------------------------------

  test "language picker is visible on the dashboard" do
    visit root_url
    assert_selector "a[href*='/locale/en']"
    assert_selector "a[href*='/locale/pt']"
  end

  test "language picker is visible on the contracts page" do
    visit contracts_url
    assert_selector "a[href*='/locale/en']"
    assert_selector "a[href*='/locale/pt']"
  end

  # ------------------------------------------------------------------
  # Flag text and country images
  # ------------------------------------------------------------------

  test "flag images are present in the language picker" do
    visit root_url
    assert_selector "img[src*='gb.png']"
    assert_selector "img[src*='pt.png']"
  end

  test "locale labels EN and PT are always shown" do
    visit root_url
    within "a[href*='/locale/en']" do
      assert_text "EN"
    end
    within "a[href*='/locale/pt']" do
      assert_text "PT"
    end
  end
end
