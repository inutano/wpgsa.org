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

function showResultTable(){
  var resultTable = $('table#resultTable');
  var uuid = getUrlParameter('uuid');
  getResultData(uuid, "z-score", "tsv").done(function(data){
    var tsv = $.tsv.toArrays(data);
    var header = tsv.splice(0,1)[0];
    var fixed = header.splice(0,3); // remove fixed cols, tf, #experiments, mean z-score
    var samples = header; // remaining cols are array of samples

    var tableHeaderRow = $('<tr>');
    var tableHeaderCols = $.merge(['TF', '#experiments', 'mean Z-score'], samples);
    $.each(tableHeaderCols, function(i, e){
      tableHeaderRow.append('<th>' + e + '</th>');
    });
    tableHeaderRow.append('</tr>');

    var tableHeader = $('<thead>');
    tableHeader.append(tableHeaderRow);
    tableHeader.append('</thead>');
    resultTable.append(tableHeader);

    resultTable.append('<tbody>');
    $.each(tsv, function(i, line){
      var row = $('<tr>')
      $.each(line, function(i, e){
        //row.append('<td>' + Math.round(parseFloat(e)*10000)/10000 + '</td>');
        row.append('<td>' + e + '</td>');
      });
      row.append('</tr>');
      resultTable.append(row);
    });
    resultTable.append('</tbody>');
  });
}
