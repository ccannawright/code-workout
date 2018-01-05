# == Schema Information
#
# Table name: test_cases
#
#  id                :integer          not null, primary key
#  negative_feedback :text
#  weight            :float(24)        not null
#  description       :text
#  created_at        :datetime
#  updated_at        :datetime
#  coding_prompt_id  :integer          not null
#  input             :text             not null
#  expected_output   :text             not null
#  static            :boolean          default(FALSE), not null
#  screening         :boolean          default(FALSE), not null
#  example           :boolean          default(FALSE), not null
#  hidden            :boolean          default(FALSE), not null
#
# Indexes
#
#  index_test_cases_on_coding_prompt_id  (coding_prompt_id)
#

# This require is to prevent autoload circular dependencies, since
# TestCaseResult is used in one of the methods.

require 'test_case_result'


# =============================================================================
# Represents a test case used to evaluate a student's answer to a coding
# prompt.
#
class TestCase < ActiveRecord::Base

  #~ Relationships ............................................................

  belongs_to :coding_prompt, inverse_of: :test_cases
  has_many :test_case_results, inverse_of: :test_case, dependent: :destroy

  scope :only_examples, -> { where(example: true) }
  scope :only_hidden, -> { where(hidden: true) }
  scope :only_static, -> { where(static: true) }
  scope :only_dynamic, -> { where(static: false) }
  scope :only_screening, -> { where(screening: false) }


  #~ Validation ...............................................................

  validates :input, presence: true, if: :no_description?
  validates :expected_output, presence: true, if: :no_description?
  validates :coding_prompt, presence: true
  validates :weight, presence: true, numericality: { greater_than_or_equal_to: 0.0 }


  #~ Instance methods .........................................................

  # -------------------------------------------------------------
  def no_description?
    self.description.blank?
  end


  # -------------------------------------------------------------
  def is_example?
    self.example
  end


  # -------------------------------------------------------------
  def apply_static_check(answer, code)
    if !self.static
      return nil
    end

    if !code
      code = answer.without_comments
    end
    required_count = nil
    required = self.expected_output.blank? ||
      self.expected_output =~ /true/i
    if self.expected_output =~ /^[0-9]+$/
      required_count = self.expected_output.to_i
      required = (required_count > 0)
    end
    options = nil
    regex = self.input
    nresp = self.negative_feedback
    nresp_operator = 'use'
    if regex =~ /^keyword(s?):/
      regex = '\b(' + to_choices(regex, /^keyword(s?):\s*/) + ')\b'
    elsif regex =~ /^class(es)?:/
      regex = '\b(' + to_choices(regex, /^class(es)?:\s*/) + ')\b'
    elsif regex =~ /^method(s?):/
      regex = '(?<!\bthis\s*)\.\s*(' +
        to_choices(regex, /^method(s?):\s*/) + ')\s*\('
    elsif regex.start_with? '/'
      nresp_operator = 'contain'
      last = regex.rindex('/')
      if last < regex.length - 1
        options = regex[(last + 1)..-1]
      end
      regex = regex[1..last]
    end
    if nresp.blank?
      if required
        nresp = 'Answer must ' + nresp_operator + ' ' + self.input
      else
        nresp = 'Answer cannot ' + nresp_operator + ' ' + self.input
      end
    end
    mdata = Regexp.new(regex, options).match(code)
    if self.screening
      if required && !mdata || !required && mdata
        return nresp
      end
    else
      passed = required && mdata || !required && !mdata
      tcr = TestCaseResult.new(
        test_case: self,
        user: answer.attempt.user,
        coding_prompt_answer: answer,
        pass: passed
      )
      if !passed
        tcr.execution_feedback = nresp
      end
    end
  end


  # -------------------------------------------------------------
  def display_description(pass = true)
    result = self.description
    if self.hidden?
      result = 'hidden'
    end
    # if result == 'example'
      # result = ''
    # elsif !result.blank? && result.start_with?('example:')
      # result = result.sub(/^example:\s*/, '')
    # end
    if result.blank?
      inp = self.input
      if !inp.blank?
        inp.gsub!(/new\s+[a-zA-Z0-9]+(\s*\[\s*\])+\s*/, '')
      end
      result = coding_prompt.method_name + '(' + inp + ')'
      if pass
        outp = self.expected_output
        if !outp.blank?
          outp.gsub!(/new\s+[a-zA-Z0-9]+(\s*\[\s*\])+\s*/, '')
        end
        result += ' -> ' + outp
      end
    end
    result
  end


  # -------------------------------------------------------------
  def record_result(answer, test_results_array)
    tcr = TestCaseResult.new(
      test_case: self,
      user: answer.attempt.user,
      coding_prompt_answer: answer,
      pass: (test_results_array.length == 8 && test_results_array[7].to_i == 1)
      )
    if !self.negative_feedback.blank?
      tcr.execution_feedback = self.negative_feedback
    else
      # This logic is somewhat Java-specific, and needs to be refactored
      # to better support other languages.
      if !test_results_array[5].blank?
        exception_name = test_results_array[5].sub(/^.*\./, '')
        if !(['AssertionFailedError',
          'AssertionError',
          'ComparisonFailure',
          'ReflectionSupportError'].include?(exception_name) ||
          (exception_name == 'Exception' &&
          test_results_array[6].start_with?('test timed out'))) ||
          test_results_array[6].blank? ||
          "null" == test_results_array[6]
          tcr.execution_feedback = exception_name
        end
      end
      if !test_results_array[6].blank? && 'null' != test_results_array[6]
        if !tcr.execution_feedback.blank?
          tcr.execution_feedback += ': '
        else
          tcr.execution_feedback = ''
        end
        if test_results_array[6].start_with? 'test timed out'
          test_results_array[6].sub!(/^test /, '')
          test_results_array[6].sub!('000 milli', ' ')
        end
        tcr.execution_feedback += test_results_array[6].sub(/^\w/, &:upcase)
      end
      if tcr.execution_feedback.blank?
        tcr.execution_feedback = 'did not meet expectations'
      end
    end
    tcr.save!

    # Return weighted score for this test result
    tcr.pass? ? self.weight : 0.0
  end


  # -------------------------------------------------------------
  def to_code(language)
    TEST_METHOD_TEMPLATES[language] % {
      id: self.id.to_s,
      method_name: coding_prompt.method_name,
      class_name: coding_prompt.class_name,
      input: self.input,
      expected_output: self.expected_output,
      negative_feedback: self.negative_feedback,
      array: ((self.expected_output.start_with?('new ') &&
        self.expected_output.include?('[]')) ||
        self.expected_output.start_with?('array(')) ? 'Array' : ''
    }
  end


  #~ Private instance methods .................................................
  private

  def to_choices(str, regex)
    str.sub(regex, '').tr(',', ' ').strip.split(/\s+/).join('|')
  end


    TEST_METHOD_TEMPLATES = {
      'Ruby' => <<RUBY_TEST,
  def test%{id}
    if %{method_name}(%{input}) ==
      %{expected_output}
      @@f.write("1,,%{id}\n")
    else
      @@f.write("0,\"%{negative_feedback}\",%{id}\n")
    end
    assert_equal(%{method_name}(%{input}), %{expected_output})
  end

RUBY_TEST
      'Python' => <<PYTHON_TEST,
    def test%{id}(self):
        if %{class_name}.%{method_name}(%{input}) == %{expected_output}:
            %{class_name}Test.f.write("1,,%{id}\n")
        else:
            %{class_name}Test.f.write("0,\"%{negative_feedback}\",%{id}\n")
        self.assertEqual(%{class_name}.%{method_name}(%{input}),%{expected_output})

PYTHON_TEST
      'Java' => <<JAVA_TEST
    @Test
    public void test_%{id}()
    {
        assertEquals(
          "%{negative_feedback}",
          %{expected_output},
          subject.%{method_name}(%{input}));
    }
JAVA_TEST
    }

end
