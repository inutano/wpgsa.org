// result.js v0.1.0
// script for wpgsa.org
// copyright: Tazro Inutano Ohta inutano@gmail.com

// onload
$(function(){
  // set filename to page header
  setResultPageHeader();
  // set buttons to download result files
  setDownloadButtons();
  // show result table
  showResultTable();
  // fix table header and cols
  fixTableHeader();
  // set linkout to heatmap
  setHeatmapLink();
});

// functions
// common

var getUrlParameter = function getUrlParameter(sParam) {
  var sPageURL = decodeURIComponent(window.location.search.substring(1)),
    sURLVariables = sPageURL.split('&'),
    sParameterName,
    i;

  for (i = 0; i < sURLVariables.length; i++) {
    sParameterName = sURLVariables[i].split('=');
    if (sParameterName[0] === sParam) {
      return sParameterName[1] === undefined ? true : sParameterName[1];
    }
  }
};

// result page rendering

getResultData = function(uuid, type, format){
  var defer = $.Deferred();
  $.ajax({
    url: "/wpgsa/result?uuid=" + uuid + "&type=" + type + "&format=" + format,
    type: 'GET',
    success: defer.resolve,
    error: defer.reject
  });
  return defer.promise();
}

function setResultPageHeader(){
  var uuid = getUrlParameter('uuid');
  getResultData(uuid, "input", "filepath").done(function(fpath){
    var filename = $('<div class="small">' + fpath.replace(/^.+\//,"") + '</div>');
    $('h2').append(filename);
  });
}

function setDownloadLink(element, type){
  var uuid = getUrlParameter('uuid');
  getResultData(uuid, type, "filepath").done(function(fpath){
    var filename = fpath.replace(/^.+\//,"");
    element.attr("href", fpath).attr("download", filename);
  });
}

function setDownloadButtons(){
  setDownloadLink($('a#pValue'), "p-value");
  setDownloadLink($('a#qValue'), "q-value");
  setDownloadLink($('a#zScore'), "z-score");
}

function addTableHeader(table, headerCols){
  var row = $('<tr>')
  $.each(headerCols, function(i, e){
    row.append('<th>' + e + '</th>');
  });
  table.append($('<thead>').append(row));
}

function addTableContents(table, tsv){ // input tsv without header columns
  var tbody = $('tbody');
  $.each(tsv, function(i, line){
    var tr = $('<tr>')
    $.each(line, function(ie, el){
      var cont = el;
      tr.append('<td>'+cont+'</td>')
    });
    tbody.append(tr);
  });
  table.append(tbody);
}

function showResultTable(){
  var resultTable = $('table#resultTable');
  var uuid = getUrlParameter('uuid');
  getResultData(uuid, "z-score", "tsv").done(function(data){
    var tsv     = $.tsv.toArrays(data);
    var header  = tsv.splice(0,1)[0];
    var fixed   = header.splice(0,3); // remove fixed cols, tf, #experiments, mean z-score
    var samples = header;             // remaning cols are array of samples
    var headerCols = $.merge(['TF', '#Experiments', 'mean Z-score'], samples);
    addTableHeader(resultTable, headerCols);
    addTableContents(resultTable, tsv);
  });
}

function fixTableHeader(){
  var table = $('table#resultTable');
}

function setHeatmapLink(){
  var uuid = getUrlParameter('uuid');
  $('button#viewHeatmap').on('click', function(){
    window.open('/result/heatmap?uuid=' + uuid, "_self", "");
  });
}
