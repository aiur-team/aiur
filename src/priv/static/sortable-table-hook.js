(function () {
  "use strict";

  var PARAM = "sort";
  var CHANGE_EVENT = "aiur:table-sort-changed";

  function stateValue(table, column, direction) {
    return [table, column, direction].join(":");
  }

  function parseState(value) {
    var parts = String(value || "").split(":");
    if (parts.length !== 3 || !parts[0] || !parts[1] || !["asc", "desc"].includes(parts[2])) return null;
    return { table: parts[0], column: parts[1], direction: parts[2] };
  }

  function clearURLSort(url) {
    url.searchParams.delete(PARAM);
    window.history.replaceState(window.history.state, "", url);
  }

  function urlState(table, headers) {
    try {
      var url = new URL(window.location.href);
      var raw = url.searchParams.get(PARAM);
      var state = parseState(raw);
      if (!raw) return null;

      var tableExists = state && Array.from(document.querySelectorAll("[data-sort-table]")).some(function (candidate) {
        return candidate.dataset.sortTable === state.table;
      });
      if (!state || !tableExists) {
        clearURLSort(url);
        return null;
      }

      if (state.table !== table) return null;
      if (!(headers || []).some(function (header) { return header.dataset.sortKey === state.column; })) {
        clearURLSort(url);
        return null;
      }

      return state;
    } catch (_error) {
      return null;
    }
  }

  function compareValues(left, right, type) {
    if (type === "number") {
      var leftNumber = Number(left);
      var rightNumber = Number(right);
      if (!Number.isNaN(leftNumber) && !Number.isNaN(rightNumber)) return leftNumber - rightNumber;
    }

    return left.localeCompare(right, undefined, { numeric: true, sensitivity: "base" });
  }

  function sortableRows(table) {
    return Array.from(table.tBodies).flatMap(function (body) {
      return sortableBodyRows(body);
    });
  }

  // A detail row is identified only by `data-sort-detail-for`, the same contract
  // `detailRows` reads, so a new table cannot become sortable-by-accident by
  // omitting a particular CSS class.
  function sortableBodyRows(body) {
    return Array.from(body.rows).filter(function (row) {
      return !row.dataset.sortDetailFor && row.cells.length > 1;
    });
  }

  function cellValue(row, columnIndex) {
    var cell = row.cells[columnIndex];
    if (!cell) return "";
    return cell.hasAttribute("data-sort-value") ? cell.dataset.sortValue : cell.textContent.trim();
  }

  function detailRows(body) {
    return new Map(Array.from(body.rows)
      .filter(function (row) { return row.dataset.sortDetailFor; })
      .map(function (row) { return [row.dataset.sortDetailFor, row]; }));
  }

  function rowKey(row) {
    return row.id || row.dataset.sortId || null;
  }

  window.AiurSortableTableHook = {
    mounted: function () {
      this.tableKey = this.el.dataset.sortTable;
      this.sequence = 0;
      this.ranks = new Map();
      this.onHeaderClick = this.headerClicked.bind(this);
      this.onExternalChange = this.externalChange.bind(this);
      this.bindHeaders();
      this.captureRanks();
      this.state = urlState(this.tableKey, this.headers);
      window.addEventListener(CHANGE_EVENT, this.onExternalChange);
      window.addEventListener("popstate", this.onExternalChange);
      this.applySort();
    },

    beforeUpdate: function () {
      this.captureRanks();
      var focused = document.activeElement;
      this.focusedId = focused && this.el.contains(focused) ? focused.id : null;
    },

    updated: function () {
      this.bindHeaders();
      this.captureRanks(true);
      this.state = urlState(this.tableKey, this.headers);
      this.applySort();
      var focused = this.focusedId && document.getElementById(this.focusedId);
      if (focused && this.el.contains(focused)) focused.focus();
      this.focusedId = null;
    },

    destroyed: function () {
      this.unbindHeaders();
      window.removeEventListener(CHANGE_EVENT, this.onExternalChange);
      window.removeEventListener("popstate", this.onExternalChange);
    },

    bindHeaders: function () {
      this.unbindHeaders();
      this.headers = Array.from(this.el.querySelectorAll("thead th[data-sort-key]"));
      this.headers.forEach(function (header) {
        header.id = "sort-" + this.tableKey + "-" + header.dataset.sortKey;
        header.tabIndex = 0;
        header.title = "Sort by " + header.textContent.trim();
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

    captureRanks: function (prune) {
      var currentKeys = new Set();
      sortableRows(this.el).forEach(function (row) {
        var key = rowKey(row);
        var rank = key && this.ranks.get(key);

        if (rank === undefined) {
          rank = this.sequence++;
          if (key) this.ranks.set(key, rank);
        }

        if (key) currentKeys.add(key);
        row.dataset.sortRank = String(rank);
      }, this);

      if (prune) {
        this.ranks.forEach(function (_rank, key) {
          if (!currentKeys.has(key)) this.ranks.delete(key);
        }, this);
      }
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
      window.dispatchEvent(new CustomEvent(CHANGE_EVENT, { detail: { sort: value } }));
      if (!this.el.hasAttribute("data-sort-client-only")) this.pushEvent("table-sort-changed", { sort: value });
    },

    externalChange: function (event) {
      var value = event.type === CHANGE_EVENT ? event.detail && event.detail.sort : new URL(window.location.href).searchParams.get(PARAM);
      var state = parseState(value);
      this.state = event.type === "popstate" ? urlState(this.tableKey, this.headers) : state && state.table === this.tableKey ? state : null;
      this.applySort();
    },

    applySort: function () {
      var state = this.state;
      var header = state && this.headers.find(function (candidate) {
        return candidate.dataset.sortKey === state.column;
      });

      this.headers.forEach(function (candidate) {
        var active = candidate === header;
        candidate.setAttribute("aria-sort", active ? (state.direction === "desc" ? "descending" : "ascending") : "none");
      });

      var columnIndex = header ? header.cellIndex : -1;
      var type = header ? (header.dataset.sortType || "text") : "text";
      var direction = header && state.direction === "desc" ? -1 : 1;

      Array.from(this.el.tBodies).forEach(function (body) {
        var rows = sortableBodyRows(body);
        var records = rows.map(function (row) {
          return { row: row, rank: Number(row.dataset.sortRank), value: header ? cellValue(row, columnIndex) : "" };
        });
        records.sort(function (left, right) {
          if (!header) return left.rank - right.rank;
          if (left.value === "" && right.value === "") return left.rank - right.rank;
          if (left.value === "") return 1;
          if (right.value === "") return -1;

          var compared = compareValues(left.value, right.value, type);
          return compared === 0 ? left.rank - right.rank : compared * direction;
        });

        if (rows.every(function (row, index) { return row === records[index].row; })) return;

        var details = detailRows(body);
        var fragment = document.createDocumentFragment();
        records.forEach(function (record) {
          fragment.appendChild(record.row);
          var detail = details.get(record.row.id);
          if (detail) fragment.appendChild(detail);
        });
        body.appendChild(fragment);
      });
    }
  };
})();
