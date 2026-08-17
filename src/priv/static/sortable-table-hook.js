(function () {
  "use strict";

  var PARAM = "sort";

  function stateValue(table, column, direction) {
    return [table, column, direction].join(":");
  }

  function parseState(value) {
    var parts = String(value || "").split(":");
    if (parts.length !== 3 || !parts[0] || !parts[1] || !["asc", "desc"].includes(parts[2])) return null;
    return { table: parts[0], column: parts[1], direction: parts[2] };
  }

  function urlState(table) {
    try {
      var state = parseState(new URL(window.location.href).searchParams.get(PARAM));
      return state && state.table === table ? state : null;
    } catch (_error) {
      return null;
    }
  }

  function compareValues(left, right, type) {
    if (left === "" && right === "") return 0;
    if (left === "") return 1;
    if (right === "") return -1;

    if (type === "number") {
      var leftNumber = Number(left);
      var rightNumber = Number(right);
      if (!Number.isNaN(leftNumber) && !Number.isNaN(rightNumber)) return leftNumber - rightNumber;
    }

    return left.localeCompare(right, undefined, { numeric: true, sensitivity: "base" });
  }

  function sortableRows(table) {
    return Array.from(table.tBodies).flatMap(function (body) {
      return Array.from(body.rows).filter(function (row) {
        return !row.classList.contains("history-detail-row") && row.cells.length > 1;
      });
    });
  }

  window.AiurSortableTableHook = {
    mounted: function () {
      this.tableKey = this.el.dataset.sortTable;
      this.sequence = 0;
      this.onHeaderClick = this.headerClicked.bind(this);
      this.bindHeaders();
      this.captureRanks();
      this.state = urlState(this.tableKey);
      this.applySort();
    },

    beforeUpdate: function () {
      this.captureRanks();
    },

    updated: function () {
      this.bindHeaders();
      this.captureRanks();
      this.state = urlState(this.tableKey) || this.state;
      this.applySort();
    },

    destroyed: function () {
      this.unbindHeaders();
    },

    bindHeaders: function () {
      this.unbindHeaders();
      this.headers = Array.from(this.el.querySelectorAll("thead th[data-sort-key]"));
      this.headers.forEach(function (header) {
        header.tabIndex = 0;
        header.setAttribute("role", "button");
        header.addEventListener("click", this.onHeaderClick);
        header.addEventListener("keydown", this.onHeaderClick);
      }, this);
    },

    unbindHeaders: function () {
      (this.headers || []).forEach(function (header) {
        header.removeEventListener("click", this.onHeaderClick);
        header.removeEventListener("keydown", this.onHeaderClick);
      }, this);
    },

    captureRanks: function () {
      sortableRows(this.el).forEach(function (row) {
        if (!row.dataset.sortRank) row.dataset.sortRank = String(this.sequence++);
      }, this);
    },

    headerClicked: function (event) {
      if (event.type === "keydown" && !["Enter", " "].includes(event.key)) return;
      event.preventDefault();

      var header = event.currentTarget;
      var column = header.dataset.sortKey;
      var direction = this.state && this.state.column === column && this.state.direction === "desc" ? "asc" : "desc";
      this.state = { table: this.tableKey, column: column, direction: direction };

      var value = stateValue(this.tableKey, column, direction);
      var url = new URL(window.location.href);
      url.searchParams.set(PARAM, value);
      window.history.replaceState(window.history.state, "", url);
      this.pushEvent("table-sort-changed", { sort: value });
      this.applySort();
    },

    applySort: function () {
      var state = this.state;
      var header = state && this.headers.find(function (candidate) {
        return candidate.dataset.sortKey === state.column;
      });

      this.headers.forEach(function (candidate) {
        var active = candidate === header;
        candidate.classList.toggle("is-sort-active", active);
        candidate.setAttribute("aria-sort", active ? (state.direction === "desc" ? "descending" : "ascending") : "none");
      });

      if (!header) return;
      var columnIndex = header.cellIndex;
      var type = header.dataset.sortType || "text";
      var direction = state.direction === "desc" ? -1 : 1;

      Array.from(this.el.tBodies).forEach(function (body) {
        var rows = sortableRows({ tBodies: [body] });
        var details = new Map(Array.from(body.rows)
          .filter(function (row) { return row.classList.contains("history-detail-row"); })
          .map(function (row) { return [row.id.replace(/^history-detail-/, ""), row]; }));
        rows.sort(function (left, right) {
          var leftCell = left.cells[columnIndex];
          var rightCell = right.cells[columnIndex];
          var leftValue = leftCell ? (leftCell.dataset.sortValue || leftCell.textContent.trim()) : "";
          var rightValue = rightCell ? (rightCell.dataset.sortValue || rightCell.textContent.trim()) : "";
          var compared = compareValues(leftValue, rightValue, type);
          return compared === 0 ? Number(left.dataset.sortRank) - Number(right.dataset.sortRank) : compared * direction;
        });
        rows.forEach(function (row) {
          body.appendChild(row);
          var detail = details.get(row.id);
          if (detail) body.appendChild(detail);
        });
      });
    }
  };

  window.AiurSortableTable = { compareValues: compareValues, parseState: parseState, stateValue: stateValue };
})();
