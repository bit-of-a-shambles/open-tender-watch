require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "flag_type_severity returns known severity from map" do
    assert_equal "high", flag_type_severity("A1_REPEAT_DIRECT_AWARD")
    assert_equal "low",  flag_type_severity("A2_PUBLICATION_AFTER_CELEBRATION")
  end

  test "flag_type_severity returns medium for unknown flag type" do
    assert_equal "medium", flag_type_severity("UNKNOWN_FLAG")
  end

  test "flag_type_severity accepts symbol" do
    assert_equal "high", flag_type_severity(:A1_REPEAT_DIRECT_AWARD)
  end
end
