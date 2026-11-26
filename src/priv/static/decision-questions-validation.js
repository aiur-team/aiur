(function () {
  "use strict";
  function validate(form) {
    form.querySelectorAll("[data-question-group]").forEach(function (group) {
      var inputs = [...group.querySelectorAll("input[type=radio], input[type=checkbox]")];
      if (!inputs.length) return;
      var selected = inputs.some(function (input) { return input.checked; });
      inputs[0].setCustomValidity(selected ? "" : "Answer this question.");
    });
  }
  document.addEventListener("change", function (event) {
    var form = event.target.closest(".decision-answer-form");
    if (form) validate(form);
  }, true);
  document.addEventListener("submit", function (event) {
    var form = event.target.closest(".decision-answer-form");
    if (!form) return;
    validate(form);
    if (!form.reportValidity()) {
      event.preventDefault();
      event.stopImmediatePropagation();
    }
  }, true);
})();
