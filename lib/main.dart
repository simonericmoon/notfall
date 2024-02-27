import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'dart:convert'; // For json decoding
import 'package:geolocator/geolocator.dart';
import 'dart:async';
import 'package:flutter/services.dart' show rootBundle;

Future<Map<String, dynamic>> loadConfig() async {
  final jsonString = await rootBundle.loadString('assets/config.json');
  return json.decode(jsonString);
}

typedef OnAmenityTap = void Function(
    String name, double lat, double lon, String amenity);

Future<List<dynamic>> fetchIsochrones(double lat, double lon) async {
  final config = await loadConfig();
  final String apiKey = config['api_key'];

  const String apiUrl =
      'https://api.openrouteservice.org/v2/isochrones/driving-car';

  final response = await http.post(
    Uri.parse(apiUrl),
    headers: {
      'Content-Type': 'application/json; charset=UTF-8',
      'Authorization': apiKey,
    },
    body: jsonEncode({
      "locations": [
        [lon, lat]
      ],
      "range": [500],
      "attributes": ["area"],
      "range_type": "time",
      "area_units": "m"
    }),
  );

  if (response.statusCode == 200) {
    final data = json.decode(response.body);
    final List<dynamic> coordinates =
        data['features'][0]['geometry']['coordinates'][0];
    return coordinates;
  } else {
    throw Exception('Failed to load isochrones');
  }
}

Future<List<Marker>> fetchLocations(OnAmenityTap onAmenityTap) async {
  const overpassUrl = 'https://overpass-api.de/api/interpreter';
  const query = '[out:json][timeout:60];'
      'area["boundary"~"administrative"]["name"~"Berlin"];'
      'node(area)["amenity"~"fire_station|police"];'
      'out;';

  final response = await http.get(
    Uri.parse('$overpassUrl?data=$query'),
  );

  if (response.statusCode == 200) {
    final data = json.decode(response.body);
    final elements = data['elements'] as List;

    return elements.map((element) {
      final lat = element['lat'];
      final lon = element['lon'];
      final amenity = element['tags']['amenity'];
      final name = element['tags']['name'] ?? 'Unknown';

      Color markerColor = Colors.red; // Default to red
      if (amenity == 'fire_station') {
        markerColor = Colors.red;
      } else if (amenity == 'police') {
        markerColor = Colors.blue;
      }

      return Marker(
        width: 80.0,
        height: 80.0,
        point: LatLng(lat, lon),
        child: GestureDetector(
          onTap: () => onAmenityTap(name, lat, lon, amenity),
          child: Icon(
            Icons.location_pin,
            color: markerColor,
            size: 40.0, // Adjust the size as needed
          ),
        ),
      );
    }).toList();
  } else {
    throw Exception('Failed to load locations from Overpass API');
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized(); // Required for async main
  final config = await loadConfig();
  final apiKey = config['api_key'];

  // Now you can use apiKey for your API calls
  runApp(MyApp(apiKey: apiKey));
}

class MyApp extends StatelessWidget {
  final String apiKey;

  MyApp({Key? key, required this.apiKey}) : super(key: key);
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: Text('Berlin Map')),
        body: MapWidget(),
      ),
    );
  }
}

class MapWidget extends StatefulWidget {
  @override
  _MapWidgetState createState() => _MapWidgetState();
}

class _MapWidgetState extends State<MapWidget> {
  late Future<List<Marker>> futureMarkers;
  Marker? userLocationMarker;
  Timer? locationUpdateTimer;
  List<Marker> apiMarkers = [];
  List<LatLng> userIsochronePoints = [];
  List<LatLng> amenityIsochronePoints = [];

  @override
  void initState() {
    super.initState();
    futureMarkers = fetchLocations(showAmenityDetails).then((markers) {
      apiMarkers = markers;
      return markers;
    });
    _getUserLocationAndUpdateIsochrone();
    locationUpdateTimer = Timer.periodic(Duration(seconds: 5),
        (Timer t) => _getUserLocationAndUpdateIsochrone());
  }

  @override
  void dispose() {
    locationUpdateTimer?.cancel();
    super.dispose();
  }

  void _getUserLocationAndUpdateIsochrone() async {
    // Fetch user location
    Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high);

    // Update user location marker
    setState(() {
      userLocationMarker = Marker(
        width: 50.0,
        height: 50.0,
        point: LatLng(position.latitude, position.longitude),
        child: Icon(Icons.person_pin_circle, color: Colors.green, size: 50.0),
      );
    });

    // Fetch and update user isochrone
    fetchIsochrones(position.latitude, position.longitude).then((points) {
      setState(() {
        userIsochronePoints = List<LatLng>.from(
            points.map((coord) => LatLng(coord[1], coord[0])));
      });
    });
  }

  void showAmenityDetails(String name, double lat, double lon, String amenity) {
    // Fetch isochrones for the amenity and update the state
    fetchIsochrones(lat, lon).then((coordinates) {
      setState(() {
        amenityIsochronePoints = List<LatLng>.from(
            coordinates.map((coord) => LatLng(coord[1], coord[0])));
      });
    });

    // Show details in a dialog
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(name),
          content: Text('Location: $lat, $lon\nType: $amenity'),
          actions: <Widget>[
            TextButton(
              child: Text('Close'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> mapLayers = [
      TileLayer(
        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
        userAgentPackageName: 'com.example.app',
      ),
      MarkerLayer(markers: apiMarkers),
    ];

    if (userLocationMarker != null) {
      mapLayers.add(MarkerLayer(markers: [userLocationMarker!]));
    }

    // Add isochrone layers for user and selected amenity
    if (userIsochronePoints.isNotEmpty) {
      mapLayers.add(PolygonLayer(
        polygons: [
          Polygon(
              points: userIsochronePoints,
              color: Colors.green.withOpacity(0.3),
              borderColor: Colors.green,
              borderStrokeWidth: 2.0)
        ],
      ));
    }

    if (amenityIsochronePoints.isNotEmpty) {
      mapLayers.add(PolygonLayer(
        polygons: [
          Polygon(
              points: amenityIsochronePoints,
              color: Colors.red.withOpacity(0.3),
              borderColor: Colors.red,
              borderStrokeWidth: 2.0)
        ],
      ));
    }

    return FutureBuilder<List<Marker>>(
      future: futureMarkers,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return FlutterMap(
            options: MapOptions(
              center: LatLng(52.5200, 13.4050), // Berlin coordinates
              zoom: 13.0,
            ),
            children: mapLayers,
          );
        } else if (snapshot.hasError) {
          return Text("${snapshot.error}");
        }
        return CircularProgressIndicator();
      },
    );
  }
}
