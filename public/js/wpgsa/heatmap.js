// heatmap.js v0.1.0
// script for wpgsa.org
// Thanks to Damian for amaging tutorial! http://blog.nextgenetics.net/?e=44

// height of each column in the heatmap
var h = 5;

// width of each column in the heatmap
var w = 70;

// attach a SVG element to the document body
var mySVG = d3.select("#heatmap")
  .append("svg")
  .attr("width", (w * cols.length) + 400)
  .attr("height", (h * rows.length) + 100)
  .style('position', 'absolute')
  .style('top', 150)
  .style('left', 150);

// define a color sacle using the min and max expression values
var colorScale = d3.scale.linear()
  .domain([minData, 0, maxData])
  .range(['blue', 'white', 'red']);

// generate heatmap rows
var heatmapRow = mySVG.selectAll(".heatmap")
  .data(data)
  .enter().append("g");

// generate heatmap columns
var heatmapRects = heatmapRow
  .selectAll(".rect")
  .data(function(d){
    return d;
  }).enter().append("svg:rect")
  .attr('width', w)
  .attr('height', h)
  .attr('x', function(d){
    return (d[2] * w) + 25;
  })
  .attr('y', function(d){
    return (d[1] * h) + 50;
  })
  .style('fill', function(d){
    return colorScale(d[0]);
  });

// label columns
var columnLabel = mySVG.selectAll(".colLabel")
  .data(cols)
  .enter().append('svg:text')
  .attr('x', function(d,i){
    return ((i + 0.5) * w) + 25;
  })
  .attr('y', 30)
  .attr('class', 'label')
  .style('text-anchor', 'middle')
  .text(function(d){
    return d;
  });

// expression value label
var expLab = d3.select("body")
  .append('div')
  .style('height', 23)
  .style('position', 'absolute')
  .style('background', 'FFE53B')
  .style('opacity', 0.8)
  .style('top', 0)
  .style('padding', 10)
  .style('left', 40)
  .style('display', 'none');

// heatmap mouse events
heatmapRow
  .on('mouseover', function(d,i){
    d3.select(this)
      .attr('stroke-width', 1)
      .attr('stroke', 'black')

    output = '<b>' + rows[i] + '</b><br>';
    for (var j = 0, count = data[i].length; j < count; j++) {
      output += data[i][j][0] + ",";
    }
    expLab
      .style('top', (i * h))
      .style('display', 'block')
      .html(output.substring(0, output.length - 3));
  })
  .on('mouseout', function(d,i){
    d3.select(this)
      .attr('stroke-width', 0)
      .attr('stroke', 'none')
    expLab
      .style('display', 'none')
  });
