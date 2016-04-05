// table.js v0.1.0
// script for wpgsa.org
// expected to be loaded with result.js
// copyright: Tazro Inutano Ohta inutano@gmail.com

// onload
$(function(){
  // set linkout to heatmap
  setHeatmapLink();
  // wait for table rendering
  waitTable();
  // build table and fix header and the column of tf name
  buildTable();
});

// result page table rendering

function waitTable(){
  $('table#resultTable')
    .on('onPreBody', function(){
      // cursor: wait
      $("body").css("cursor", "progress");
    })
    .on('onPostBody', function(){
      // cursor: finish
      $("body").css("cursor", "default");
    });
}

function buildTable(tsv){
  // start build
  var uuid = getUrlParameter('uuid');
  getResultData(uuid, "z-score", "tsv").done(function(tsvData){
    var tsv     = $.tsv.toArrays(tsvData);
    var header  = tsv.splice(0,1)[0];
    var fixed   = header.splice(0,3); // remove fixed cols, tf, #experiments, mean z-score
    var samples = header;             // remaning cols are array of samples
    var headerCols = $.merge(['TF', '#Experiments', 'mean Z-score'], samples);

    var row;
    var columns = [];
    var data = [];

    $.each(headerCols, function(i, el){
      columns.push({
        field: 'field_' + el,
        title: el,
        sortable: true
      });
    });

    $.each(tsv, function(i, line){
      row = {};
      $.each(line, function(j, cont){
        if (j > 1) {
          var v = parseFloat(cont).toFixed(4);
        }else {
          var v = cont;
        }
        row['field_' + headerCols[j]] = v;
      });
      data.push(row);
    });

    var table = $('table#resultTable');
    table.bootstrapTable('destroy').bootstrapTable({
      columns: columns,
      data: data,
      //search: true,
      toolbar: '.toolbar',
      fixedHeader: true,
      fixedColumns: true,
      fixedNumber: 1,
    });
  });
}

function setHeatmapLink(){
  var uuid = getUrlParameter('uuid');
  $('a#viewHeatmap').attr("href","/result/heatmap?uuid=" + uuid);
}
